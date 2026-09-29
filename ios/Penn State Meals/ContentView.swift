//
//  ContentView.swift
//  Penn State Meals
//
//  Created by Ryan Nair on 2/1/23.
//

import SwiftUI
import CoreSpotlight
import WidgetKit
import FirebaseAnalytics
import FirebaseCore
import UIKit

private extension View {
    
    @available(iOS 18.0, *)
    func swiftUIColor(_ selectedColor: CFIndex) -> Color? {
        switch selectedColor {
        case 1:
            return Color.white.mix(with: Color(uiColor: UIColor.magenta), by: 0.4)
        case 2:
            return .green
        case 3:
            return .teal
        case 4:
            return .red
        case 5:
            return .purple
        case 6:
            return .indigo
        default:
            return nil
        }
    }
    
    @ViewBuilder
    func adaptiveTabViewStyle(_ selectedColor: CFIndex) -> some View {
        if #available(iOS 18.0, *) {
            self.tint(swiftUIColor(selectedColor))
        } else {
            let _ = swizzleCustomTintColor(selectedColor)
            self.tabViewStyle(.automatic)
        }
    }
}

enum University: String, CaseIterable {
    case psu, Barnard, uga, none
    
    var fullName: String {
        switch self {
        case .psu:
            return "Penn State"
        case .Barnard:
            return "Barnard"
        case .uga:
            return "University of Georgia"
        case .none:
            return "N/A"
        }
    }
}

/// Persisted choices for a normal PSU app launch. External routes always take priority.
enum AppLaunchDestination: String, CaseIterable {
    case meals, cata, north, south, east, west, pollock

    var title: LocalizedStringResource {
        switch self {
        case .meals: "Meals"
        case .cata: "CATA"
        case .north: "North Dining Hall"
        case .south: "South Dining Hall"
        case .east: "East Dining Hall"
        case .west: "West Dining Hall"
        case .pollock: "Pollock Dining Hall"
        }
    }
}

struct ContentView: View {
    let appDelegate: AppDelegate
    @State private var selectedTab = 0
    @State private var hasHandledLaunchDestination = false
    @AppStorage("proLaunchDestination") private var launchDestination: AppLaunchDestination = .meals
    @State private var linkedUniversityTab: Int?
    @AppStorage("customTintColor") var selectedColor: CFIndex = 0
    @Environment(\.scenePhase) private var diningScenePhase
    @AppStorage("selectedUniversity", store: .shared) var selectedUniversity: University?
    @State private var purchaseManager = PurchaseManager()
    @State private var mealJournal = MealJournal()

    private var isBTChatSelected: Bool {
        guard let selectedUniversity else { return false }
        return selectedTab == (selectedUniversity == .none ? 0 : 1)
    }

    var body: some View {
        Group {
        if let selectedUniversity {
            TabView(selection: Binding(get: { selectedTab }, set: {
                // A user's tab choice wins over the initial launch preference.
                hasHandledLaunchDestination = true
                selectedTab = $0
            })) {
                if selectedUniversity == .none {
                    NavigationStack {
                        BitchatApp()
                    }
                        .tabItem {
                            Label("BTChat", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .tag(0)
                    
                    AboutView(storedColor: $selectedColor, manager: purchaseManager, selectedUniversity: $selectedUniversity)
                        .tabItem {
                            Label("Settings", systemImage: "gear")
                        }
                        .tag(1)
                }
                else {
                    Group {
                        switch selectedUniversity {
                        case .psu, .none:
                            DiningHallListView(
                                purchaseManager: purchaseManager,
                                mealJournal: mealJournal,
                                environment: .shared
                            )
                        case .Barnard:
                            BarnardMealsView()
                        case .uga:
                            UGAMealsView()
                        }
                    }
                    .tabItem {
                        Label("Meals", systemImage: "menucard")
                    }
                    .tag(0)
                    
                    NavigationStack {
                        BitchatApp()
                    }
                        .tabItem {
                            Label("BTChat", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .tag(1)
                    
                    switch selectedUniversity {
                    case .psu, .none:
                        let cataBusView = CATABusController(purchaseManager: purchaseManager)
                            .tabItem {
                                Label("CATA", systemImage: "bus.fill")
                            }
                            .tag(2)
                        
                        if #available(iOS 26.0, *) {
                            cataBusView
                                .ignoresSafeArea()
                        } else {
                            cataBusView
                        }
                    case .uga:
                        WebEatsView(url: URL(string: "https://dining.uga.edu/locations/").unsafelyUnwrapped)
                            .tabItem {
                                Label("Info", systemImage: "takeoutbag.and.cup.and.straw")
                            }
                            .tag(2)
                    case .Barnard:
                        WebEatsView(url: URL(string: "https://barnard.edu/restaurants").unsafelyUnwrapped)
                            .tabItem {
                                Label("Restaurants", systemImage: "takeoutbag.and.cup.and.straw")
                            }
                            .tag(2)
                    }
                    
                    AboutView(storedColor: $selectedColor, manager: purchaseManager, selectedUniversity: $selectedUniversity)
                        .tabItem {
                            Label("Settings", systemImage: "gear")
                        }
                        .tag(3)
                }
            }
            .adaptiveTabViewStyle(selectedColor)
            .onAppear {
                if MealReminderNavigation.hasPendingRecord {
                    hasHandledLaunchDestination = true
                    self.selectedUniversity = .psu
                    selectedTab = 0
                }
                let tabBarAppearance = UITabBarAppearance()
                tabBarAppearance.configureWithDefaultBackground()
                UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
                if FirebaseApp.app() != nil {
                    Analytics.logEvent(AnalyticsEventScreenView, parameters: [AnalyticsParameterScreenName: "main_content"])
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetAndEatOpenMealRecord)) { _ in
                hasHandledLaunchDestination = true
                self.selectedUniversity = .psu
                selectedTab = 0
            }
            .overlay(alignment: .top) {
                AppWeatherOverlay(purchaseManager: purchaseManager)
            }
        }
        else {
            OnboardingView(selectedUniversity: $selectedUniversity)
        }
        }
        .task(id: selectedUniversity) {
            guard selectedUniversity != nil, !hasHandledLaunchDestination else { return }
            hasHandledLaunchDestination = true
            guard !MealReminderNavigation.hasPendingRecord, MeetAndEatLinkNavigation.pending == nil,
                  selectedUniversity == .psu, purchaseManager.hasUnlockedPro else { return }
            switch launchDestination {
            case .meals: break
            case .cata: selectedTab = 2
            case .north, .south, .east, .west, .pollock:
                open(.hall(launchDestination.rawValue, date: nil, meal: nil))
            }
        }
        .onChange(of: isBTChatSelected, initial: true) { _, selected in
            appDelegate.isBTChatSelected = selected
        }
        .task {
            if PSUDiningAccess.isEnabled, let pending = MeetAndEatLinkNavigation.pending { open(pending.route) }
            await purchaseManager.updatePurchasedProducts()
            await PSUDiningSpotlight.shared.synchronize()
            if #available(iOS 26.0, *) { await PSUDiningSuggestions.shared.update() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetAndEatIntentNavigation)) { _ in
            if PSUDiningAccess.isEnabled, let pending = MeetAndEatLinkNavigation.pending { open(pending.route) }
        }
        .onChange(of: diningScenePhase) { _, phase in
            if phase == .active { Task { await PSUDiningSpotlight.shared.synchronize() } }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard PSUDiningAccess.isEnabled,
                  let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let url = PSUDiningLinks.spotlightURL(identifier: id),
                  let route = MeetAndEatDeepLink(url: url) else { return }
            open(route)
        }
        .onChange(of: selectedUniversity) {
            selectedTab = linkedUniversityTab ?? 0
            linkedUniversityTab = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "PSUDiningMenuWidget-v1")
            Task(priority: .background) {
                await PSUDiningSpotlight.shared.synchronize()
                if #available(iOS 26.0, *) { await PSUDiningSuggestions.shared.update() }
                await NSUserActivity.deleteAllSavedUserActivities()
            }
        }
        .onOpenURL { url in
            if ["psu-food", "psu-menu"].contains(url.host?.lowercased() ?? ""), !PSUDiningAccess.isEnabled { return }
            guard let route = MeetAndEatDeepLink(url: url) else { return }
            open(route)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL, let route = MeetAndEatDeepLink(url: url) else { return }
            open(route)
        }
        .onContinueUserActivity("com.ryannair05.pennstatemeals.cata") { _ in
            open(.cata(routeID: nil, stopID: nil))
        }
        .onContinueUserActivity("com.ryannair05.pennstatemeals.view-hall") { activity in
            let info = activity.userInfo
            guard (info?[DiningDeepLinkUserInfoKey.provider] as? String ?? "psu") == "psu",
                  let hall = info?[DiningDeepLinkUserInfoKey.hall] as? String else { return }
            guard let route = MeetAndEatDeepLink(
                hallID: hall,
                date: info?[DiningDeepLinkUserInfoKey.date] as? String,
                meal: info?[DiningDeepLinkUserInfoKey.meal] as? String
            ) else { return }
            open(route)
        }
    }

    private func open(_ route: MeetAndEatDeepLink) {
        hasHandledLaunchDestination = true
        MeetAndEatLinkNavigation.queue(route)
        linkedUniversityTab = selectedUniversity == .psu ? nil : route.tab
        selectedUniversity = .psu
        selectedTab = route.tab
        NotificationCenter.default.post(name: .meetAndEatOpenLink, object: nil)
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(appDelegate: AppDelegate())
    }
}

@MainActor
private struct AppWeatherOverlay: View {
    let purchaseManager: PurchaseManager
    @AppStorage("manualWeatherEffect") private var manualWeatherEffect: ManualWeatherEffect = .none

    private var displayedWeather: WeatherCondition {
        if purchaseManager.liveWeather {
            return purchaseManager.hasUnlockedPro ? purchaseManager.weather : .clear
        }
        guard !manualWeatherEffect.requiresPro || purchaseManager.hasUnlockedPro else { return .clear }
        return manualWeatherEffect.condition
    }

    var body: some View {
        WeatherEffectView(condition: displayedWeather)
            .ignoresSafeArea()
    }
}
