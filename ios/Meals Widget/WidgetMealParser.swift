import Foundation

/// Presentation only. Menu loading is owned by the same PSU repositories as the app.
struct WidgetMealSection: Sendable, Identifiable {
    let id: String
    let name: String
    let items: [WidgetMealItem]
}

struct WidgetMealItem: Sendable, Identifiable {
    let id: String
    let name: String
}
