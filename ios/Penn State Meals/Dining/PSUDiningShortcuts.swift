import AppIntents

@available(iOS 26.0, *)
struct DiningHallShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetPSUDiningMenuIntent(), phrases: [
            "Get the menu with \(.applicationName)",
            "Show the menu with \(.applicationName)",
            "Show the menu at \(\.$diningHall) with \(.applicationName)",
            "Get the \(\.$diningHall) menu with \(.applicationName)",
            "What's on the menu at \(\.$diningHall) with \(.applicationName)"
        ], shortTitle: "Dining Menu", systemImageName: "fork.knife")
        AppShortcut(intent: FindPSUFoodIntent(), phrases: [
            "Find food with \(.applicationName)",
            "Find food at \(\.$diningHall) with \(.applicationName)",
            "Find something to eat at \(\.$diningHall) with \(.applicationName)"
        ], shortTitle: "Find Food", systemImageName: "magnifyingglass")
        AppShortcut(intent: GetPSUNutritionIntent(), phrases: ["Get nutrition with \(.applicationName)"], shortTitle: "Food Nutrition", systemImageName: "carrot")
        AppShortcut(intent: OpenPSUDiningMenuIntent(), phrases: [
            "Open a dining hall in \(.applicationName)",
            "Open dining halls with \(.applicationName)",
            "Open \(\.$target) in \(.applicationName)",
            "Open the dining menu for \(\.$target) with \(.applicationName)"
        ], shortTitle: "Open Dining Hall", systemImageName: "building.2")
    }
}
