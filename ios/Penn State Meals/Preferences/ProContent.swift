//
//  ProContent.swift
//  Meet and Eat
//
//  Created by Ryan Nair on 9/12/25.
//

import SwiftUI
import StoreKit
import Observation
import Combine
import FirebaseAnalytics
import FirebaseCore

struct ProContent: View {
    let purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss
    @State private var showSubscriptions = false
    @State private var restoring = false
    @State private var purchaseMessage: String?
    var mealIntroduction = false

    var body: some View {
#if OPEN_SOURCE_BUILD
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("All features included").font(.largeTitle.bold())
                Text("This open-source build includes Halls Pro features without a purchase.")
                Text("Some services, such as live weather, require your own service configuration.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
#else
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProBenefitsView(mealIntroduction: mealIntroduction)

                if purchaseManager.hasLifetimePro {
                    Label("Lifetime Pro Active", systemImage: "checkmark.seal.fill")
                } else {
                    if !purchaseManager.purchasedProductIDs.contains(PurchaseManager.proProductID) {
                        ProductView(id: PurchaseManager.proProductID)
                            .productViewStyle(.compact)
                        Text("Monthly membership automatically renews until canceled.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ProductView(id: PurchaseManager.lifetimeProductID)
                        .productViewStyle(.compact)
                    Text("Lifetime is a one-time purchase. No renewal or expiration.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if purchaseManager.purchasedProductIDs.contains(PurchaseManager.proProductID) {
                    Text("Buying lifetime does not cancel your monthly subscription. Manage your subscription to stop future renewals.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Manage Subscription") { showSubscriptions = true }
                }
                Button(restoring ? "Restoring Purchases…" : "Restore Purchases") {
                    restoring = true
                    Task {
                        defer { restoring = false }
                        do {
                            try await AppStore.sync()
                            await purchaseManager.updatePurchasedProducts(force: true)
                            if purchaseManager.hasUnlockedPro { dismiss() }
                            else { purchaseMessage = String(localized: "No active Halls Pro purchases were found for this Apple Account.") }
                        } catch {
                            purchaseMessage = String(localized: "Purchases could not be restored. Please try again.")
                        }
                    }
                }
                .disabled(restoring)
                HStack {
                    Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula").unsafelyUnwrapped)
                    Link("Privacy Policy", destination: URL(string: "https://swiftbyte.app/privacypolicy").unsafelyUnwrapped)
                }
                .font(.footnote)
            }
            .padding(24)
        }
        .onInAppPurchaseCompletion { _, result in
            switch result {
            case .success(.success(.verified(let transaction))):
                if FirebaseApp.app() != nil {
                    Analytics.logTransaction(transaction)
                }
                await purchaseManager.updatePurchasedProducts(force: true)
                await transaction.finish()
                if purchaseManager.hasUnlockedPro { dismiss() }
            case .success(.pending):
                purchaseMessage = String(localized: "Your purchase is awaiting approval. Pro will unlock when Apple confirms it.")
            case .success(.success(.unverified)), .failure:
                purchaseMessage = String(localized: "Your purchase could not be verified or completed. Please try again or restore purchases.")
            case .success(.userCancelled): break
            @unknown default: break
            }
        }
        .manageSubscriptionsSheet(isPresented: $showSubscriptions)
        .alert("Halls Pro", isPresented: Binding(get: { purchaseMessage != nil }, set: { if !$0 { purchaseMessage = nil } })) {
            Button("OK", role: .cancel) { purchaseMessage = nil }
        } message: {
            Text(purchaseMessage ?? "")
        }
        .task { await purchaseManager.updatePurchasedProducts() }
#endif
    }
}

private struct ProBenefitsView: View {
    let mealIntroduction: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Halls Pro").font(.largeTitle.bold())
            Text("Choose monthly or lifetime access to all Pro features.")
                .foregroundStyle(.secondary)
            if mealIntroduction {
                Text("Build a plate from Penn State menus, see its published nutrition, and keep your meals in one place with Pro.")
                    .foregroundStyle(.secondary)
                Text("Saved on this device. Your saved meals stay available to read, export, and delete if Pro expires.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ProFeatureRow(iconName: "arrow.up.forward.app.fill", title: "Your Launch Destination",
                          subtitle: "Open directly to CATA, your favorite dining hall, or another tab", iconColor: .blue)
            ProFeatureRow(iconName: "fork.knife.circle.fill", title: "Build My Plate",
                          subtitle: "Combine menu items and see the plate’s published nutrition", iconColor: .orange)
            ProFeatureRow(iconName: "chart.line.uptrend.xyaxis", title: "Nutrition History",
                          subtitle: "See nutrition from the meals you’ve logged", iconColor: .green)
            ProFeatureRow(iconName: "bus.fill", title: "Campus Shuttles",
                          subtitle: "Track Penn State shuttles, see arrivals and occupancy, and choose satellite maps", iconColor: .indigo)
            ProFeatureRow(iconName: "cloud.sun.rain.fill", title: "Live Weather Effects",
                          subtitle: "See real-time weather animations like rain or snow in the app", iconColor: .cyan)
        }
    }
}

struct ProFeatureRow: View {
    let iconName: String
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let iconColor: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.largeTitle)
                .foregroundColor(iconColor)
                .frame(width: 50)
            
            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

extension Notification.Name {
    static let proEntitlementsDidChange = Notification.Name("ProEntitlementsDidChange")
}

@Observable @MainActor
final class PurchaseManager {
    static let proProductID = "promonthly"
    static let lifetimeProductID = "prolifetime"
    private static let cachedProductIDsKey = "cachedProProductIDs"
    private static let lastEntitlementRefreshKey = "proEntitlementsRefreshedAt"
    private static let entitlementRefreshInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let cachedProAccessKey = "cachedProAccess"

    private(set) var purchasedProductIDs = Set<String>() {
        didSet {
            guard oldValue != purchasedProductIDs else { return }
            NotificationCenter.default.post(name: .proEntitlementsDidChange, object: self)
        }
    }
    var liveWeather: Bool {
        didSet {
            if UserDefaults.standard.bool(forKey: "liveWeather") != liveWeather {
                UserDefaults.standard.set(liveWeather, forKey: "liveWeather")
            }
        }
    }
    var weather: WeatherCondition = .clear
    
    @ObservationIgnored private var preferencesObservation: AnyCancellable?
    @ObservationIgnored private var updates: Task<Void, Never>? = nil
    
    init() {
        liveWeather = UserDefaults.standard.bool(forKey: "liveWeather")
        if let cached = UserDefaults.standard.stringArray(forKey: Self.cachedProductIDsKey) {
            purchasedProductIDs = Set(cached).intersection([Self.proProductID, Self.lifetimeProductID])
        } else if UserDefaults.standard.bool(forKey: Self.cachedProAccessKey) {
            purchasedProductIDs.insert(Self.proProductID)
        }
        // Preserve AppStorage's cross-window preference updates without broad
        // ObservableObject invalidation or stacking wrappers on observed state.
        preferencesObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.liveWeather = UserDefaults.standard.bool(forKey: "liveWeather")
                }
            }
#if !OPEN_SOURCE_BUILD
        updates = observeTransactionUpdates()
#endif
    }
    
    deinit {
        updates?.cancel()
    }
    
    /// A computed property to easily check if the user has access to Pro features.
    var hasUnlockedPro: Bool {
#if OPEN_SOURCE_BUILD
        true
#else
        !purchasedProductIDs.isEmpty
#endif
    }
    
    var hasLifetimePro: Bool { purchasedProductIDs.contains(Self.lifetimeProductID) }

    /// Normal app use trusts the local entitlement cache for a week.
    /// Purchases, restores, and transaction updates bypass that interval.
    func updatePurchasedProducts(force: Bool = false) async {
#if !OPEN_SOURCE_BUILD
        if !force,
           let refreshedAt = UserDefaults.standard.object(forKey: Self.lastEntitlementRefreshKey) as? Date,
           (0..<Self.entitlementRefreshInterval).contains(Date.now.timeIntervalSince(refreshedAt)) {
            return
        }
        var activeProductIDs = Set<String>()

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }
            
            guard transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            switch (transaction.productID, transaction.productType) {
            case (Self.proProductID, .autoRenewable):
                // currentEntitlements also includes subscriptions in their billing grace period.
                activeProductIDs.insert(transaction.productID)
            case (Self.lifetimeProductID, .nonConsumable):
                activeProductIDs.insert(transaction.productID)
            default: break
            }
        }

        guard !Task.isCancelled else { return }
        purchasedProductIDs = activeProductIDs
        UserDefaults.standard.set(Date.now, forKey: Self.lastEntitlementRefreshKey)
        UserDefaults.standard.set(Array(activeProductIDs), forKey: Self.cachedProductIDsKey)
#endif
    }
    
    /// Listens for transaction updates in the background.
    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = result,
                      [Self.proProductID, Self.lifetimeProductID].contains(transaction.productID) else { continue }
                await self.updatePurchasedProducts(force: true)
                await transaction.finish()
            }
        }
    }
}

#Preview {
    ProContent(purchaseManager: PurchaseManager())
}
