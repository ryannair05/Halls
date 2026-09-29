import HealthKit
import SwiftUI
import UIKit
import Observation
import Combine

extension Notification.Name {
    static let mealPlateDidChange = Notification.Name("MealPlateDidChange")
}

@Observable @MainActor
final class MealFeatureCoordinator {
    let journal: MealJournal
    let purchaseManager: PurchaseManager
    let environment: DiningMenuEnvironment
    private(set) var draft: PlateDraft? {
        get { journal.activeDraft }
        set { journal.activeDraft = newValue }
    }
    @ObservationIgnored private var entitlementObservation: AnyCancellable?
    @ObservationIgnored weak var navigationRoot: UIViewController?
    private var navigationController: UINavigationController? {
        navigationRoot?.navigationController
    }
    @ObservationIgnored private var nutritionTask: Task<Void, Never>?

    init(journal: MealJournal, purchaseManager: PurchaseManager, environment: DiningMenuEnvironment) {
        self.journal = journal
        self.purchaseManager = purchaseManager
        self.environment = environment
        entitlementObservation = NotificationCenter.default.publisher(for: .proEntitlementsDidChange, object: purchaseManager).sink { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.changed() }
        }
    }

    func changed() { NotificationCenter.default.post(name: .mealPlateDidChange, object: self) }

    func openJournal(recordID: UUID? = nil) {
        guard let navigationController else { return }
        navigationController.pushViewController(makeJournalViewController(recordID: recordID), animated: true)
    }

    func makeJournalViewController(recordID: UUID? = nil) -> UIViewController {
        let exportPresentation = MealExportPresentation()
        let controller = UIHostingController(rootView:
            MyMealsView(feature: self, initialRecordID: recordID, exportPresentation: exportPresentation)
                .navigationBarTitleDisplayMode(.large)
        )
        controller.title = "My Meals"
        controller.navigationItem.largeTitleDisplayMode = .always
        // UIKit owns this navigation bar; SwiftUI toolbar items are not installed here.
        let exportMenu = UIDeferredMenuElement.uncached { [journal, exportPresentation] completion in
            let csv = UIAction(title: "CSV File", image: UIImage(systemName: "tablecells"),
                               attributes: journal.hasSavedData ? [] : .disabled) { _ in
                exportPresentation.csvDocument = MealCSVDocument(records: journal.savedRecords)
                exportPresentation.exporting = true
            }
            let health = UIAction(title: "Apple Health", image: UIImage(systemName: "heart.fill"),
                                  attributes: exportPresentation.exportingHealth || journal.records(status: .eaten).isEmpty || !HKHealthStore.isHealthDataAvailable() ? .disabled : []) { _ in
                exportPresentation.confirmsHealthExport = true
            }
            var actions: [UIMenuElement] = [csv, health]
            if !journal.records(status: .planned).isEmpty {
                actions.append(UIAction(title: "Previously Saved Plans", image: UIImage(systemName: "calendar")) { _ in
                    exportPresentation.showsSavedPlans = true
                })
            }
            completion(actions)
        }
        let exportButton = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"),
                                           menu: UIMenu(title: "Export", children: [exportMenu]))
        exportButton.accessibilityLabel = "Export meals"
        controller.navigationItem.rightBarButtonItem = exportButton
        return controller
    }

    func requirePro(from host: UIViewController, action: @escaping @MainActor () -> Void) {
        guard !purchaseManager.hasUnlockedPro else { action(); return }
        let controller = UIHostingController(rootView: MealProIntroduction(purchaseManager: purchaseManager) { [weak host] in
            host?.dismiss(animated: true, completion: action)
        })
        host.present(controller, animated: true)
    }

    func start(context: PlateContext, from host: UIViewController, adding item: DiningMenuItem? = nil) {
        requirePro(from: host) { [weak self, weak host] in
            guard let self, let host else { return }
            if let draft, draft.context != context {
                let alert = UIAlertController(
                    title: "You have a plate in progress",
                    message: "\(draft.context.title) · \(draft.context.dateLabel)", preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Continue Current Plate", style: .default) { [weak self, weak host] _ in
                    guard let self, let host else { return }
                    self.showPlate(from: host)
                })
                alert.addAction(UIAlertAction(title: "Discard and Start New", style: .destructive) { [weak self, weak host] _ in
                    guard let self, let host else { return }
                    self.replaceDraft(context: context, item: item)
                    if item != nil { self.showPlate(from: host) }
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                host.present(alert, animated: true)
                return
            }
            if draft == nil { replaceDraft(context: context, item: nil) }
            if let item {
                draft?.add(item)
                loadNutrition()
                showPlate(from: host)
            }
            changed()
        }
    }

    private func replaceDraft(context: PlateContext, item: DiningMenuItem?) {
        nutritionTask?.cancel()
        draft = PlateDraft(context: context)
        if let item { draft?.add(item); loadNutrition() }
        changed()
    }

    func toggle(_ item: DiningMenuItem, context: PlateContext) {
        guard purchaseManager.hasUnlockedPro, let draft, draft.context == context else { return }
        if draft.contains(item) { draft.remove(item.id) } else { draft.add(item) }
        loadNutrition()
        changed()
    }

    func loadNutrition() {
        // Chain batches rather than overlap tasks that can update the same draft.
        let preceding = nutritionTask
        let current = draft
        let environment = environment
        nutritionTask = Task { [weak self] in
            await preceding?.value
            guard !Task.isCancelled, let current else { return }
            await current.loadNutrition(environment: environment)
            self?.changed()
        }
    }

    func discardDraft() {
        nutritionTask?.cancel()
        nutritionTask = nil
        draft = nil
        changed()
    }

    func repeatMeal(_ record: MealRecord) -> PlateDraft? {
        guard purchaseManager.hasUnlockedPro, let hall = record.hall, let date = record.menuDate else { return nil }
        let copy = PlateDraft(context: PlateContext(hall: hall, date: date, mealName: record.servicePeriodName), record: record)
        copy.recordID = nil
        discardDraft()
        draft = copy
        changed()
        return copy
    }

    func didSave(_ savedDraft: PlateDraft) {
        if draft === savedDraft { discardDraft() }
        changed()
    }

    func showPlate(from host: UIViewController) {
        guard let draft else { return }
        requirePro(from: host) { [weak self, weak host] in
            guard let self, let host else { return }
            host.present(UIHostingController(rootView: NavigationStack {
                MealEditorView(feature: self, draft: draft)
            }.mealSheetStyle()), animated: true)
        }
    }

    func openMenu(_ context: PlateContext) {
        guard let navigationController else { return }
        let controller = MealsViewController(
            diningHall: context.hall, preferredDate: context.date,
            preferredMeal: DiningDeepLinkMeal(displayName: context.mealName),
            environment: environment, mealFeature: self, startsPlate: true
        )
        controller.title = context.hall.rawValue.capitalized
        navigationController.pushViewController(controller, animated: true)
    }
}

struct MealProIntroduction: View {
    let purchaseManager: PurchaseManager
    let onUnlocked: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProContent(purchaseManager: purchaseManager, mealIntroduction: true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) }
                }
        }
        .onChange(of: purchaseManager.hasUnlockedPro) { _, unlocked in
            if unlocked { onUnlocked() }
        }
        .task { await purchaseManager.updatePurchasedProducts() }
    }
}

struct PlateMenuPicker: UIViewControllerRepresentable {
    let feature: MealFeatureCoordinator
    let draft: PlateDraft
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = MealsViewController(
            diningHall: draft.context.hall, preferredDate: draft.context.date,
            preferredMeal: DiningDeepLinkMeal(displayName: draft.context.mealName),
            environment: feature.environment, mealFeature: feature,
            editingPlate: draft, plateDone: onDone
        )
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"), primaryAction: UIAction { _ in onDone() }
        )
        controller.navigationItem.leftBarButtonItem?.accessibilityLabel = "Done choosing foods"
        return UINavigationController(rootViewController: controller)
    }
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

struct MealItemDetailSheet: UIViewControllerRepresentable {
    let item: DiningMenuItem
    let context: PlateContext
    let environment: DiningMenuEnvironment
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = MenuItemDetailViewController(
            item: item, environment: environment, providerID: .pennState,
            sourceLocationID: self.context.hall.locationID, sourceDate: self.context.date
        )
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in dismiss() }
        )
        controller.navigationItem.leftBarButtonItem?.accessibilityLabel = "Close item details"
        return UINavigationController(rootViewController: controller)
    }
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}
