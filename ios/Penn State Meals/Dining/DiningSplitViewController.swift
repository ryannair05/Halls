import UIKit

/// Owns the dining list/detail relationship. UIKit manages column collapse and expansion.
@MainActor
final class DiningSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    let hallList: DiningHallListViewController
    private let mealFeature: MealFeatureCoordinator
    private var detailRoot: UIViewController?
    private let lastViewedLocationStore: LastViewedDiningLocationStore
    private var restorationTask: Task<Void, Never>?
    private var restoredInitialDestination = false

    var detailNavigationController: UINavigationController? {
        detailRoot?.navigationController
    }

    init(
        purchaseManager: PurchaseManager,
        mealJournal: MealJournal,
        environment: DiningMenuEnvironment
    ) {
        let feature = MealFeatureCoordinator(
            journal: mealJournal, purchaseManager: purchaseManager, environment: environment
        )
        mealFeature = feature
        lastViewedLocationStore = environment.lastViewedLocationStore
        hallList = DiningHallListViewController(
            purchaseManager: purchaseManager,
            mealJournal: mealJournal,
            environment: environment,
            mealFeature: feature
        )
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        primaryBackgroundStyle = .sidebar
        minimumPrimaryColumnWidth = 300
        maximumPrimaryColumnWidth = 420
        preferredPrimaryColumnWidthFraction = 0.32
        setViewController(UINavigationController(rootViewController: hallList), for: .primary)
        setViewController(DiningSelectionViewController(), for: .secondary)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        restorationTask?.cancel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoreExpandedDestinationIfNeeded()
    }

    func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        hallList.updateDestinationSelection()
        restoreExpandedDestinationIfNeeded()
    }

    func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
        hallList.updateDestinationSelection()
        restorationTask?.cancel()
        restorationTask = nil
    }

    private func restoreExpandedDestinationIfNeeded() {
        guard !isCollapsed, viewIfLoaded?.window != nil,
              detailRoot == nil, !restoredInitialDestination, restorationTask == nil else { return }
        restorationTask = Task { @MainActor [weak self, lastViewedLocationStore] in
            let location = await lastViewedLocationStore.locationID()
            guard let self, !Task.isCancelled else { return }
            restorationTask = nil
            // Never replace a user selection or an incoming deep link while reading history.
            guard !isCollapsed, detailRoot == nil,
                  MeetAndEatLinkNavigation.pending == nil else { return }
            restoredInitialDestination = true
            hallList.restoreLastDestination(fallbackLocation: location)
        }
    }

    func showDestination(_ controller: UIViewController, animated: Bool = true) {
        restorationTask?.cancel()
        restorationTask = nil
        restoredInitialDestination = true
        detailRoot = controller
        mealFeature.navigationRoot = controller
        let navigation = UINavigationController(rootViewController: controller)
        navigation.navigationBar.prefersLargeTitles = true
        let showDestination = {
            self.setViewController(navigation, for: .secondary)
            self.show(.secondary)
        }
        if animated {
            showDestination()
        } else {
            UIView.performWithoutAnimation(showDestination)
        }
    }

    func showDiningHome() {
        restorationTask?.cancel()
        restorationTask = nil
        restoredInitialDestination = true
        detailRoot = nil
        mealFeature.navigationRoot = nil
        hallList.clearDestinationSelection()
        setViewController(DiningSelectionViewController(), for: .secondary)
        show(.primary)
    }

    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        // A fresh compact launch should show the list, never the empty detail.
        detailRoot == nil ? .primary : proposedTopColumn
    }

}

/// An explicit empty state also handles people without any saved dining destination.
@MainActor
private final class DiningSelectionViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        var content = UIContentUnavailableConfiguration.empty()
        content.image = UIImage(systemName: "menucard")
        content.text = "Explore PSU Dining"
        content.secondaryText = "Choose a dining hall or another location from the sidebar to get started."
        let emptyView = UIContentUnavailableView(configuration: content)
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            emptyView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
        ])
    }
}
