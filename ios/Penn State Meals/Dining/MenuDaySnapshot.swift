import Foundation

struct MenuDaySnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let key: MenuDayKey
    let fetchedAt: Date
    let sourceContentHash: String
    let meals: [MenuMealPeriod]

    var hasPublishedItems: Bool {
        meals.contains { meal in
            meal.sections.contains { !$0.items.isEmpty }
        }
    }
}

/// Provider-supplied item details that arrived with the menu response. Keeping this data beside
/// the item lets providers such as Nutrislice participate in the existing detail UI without a
/// second endpoint or a provider-specific screen. A missing field remains unknown; it is never
/// interpreted as an allergen-free claim.
struct DiningMenuItemDetailMetadata: Codable, Sendable, Equatable {
    let sourceURL: URL
    let fetchedAt: Date
    let ingredients: String?
    let allergenStatement: String?
    let nutrition: [DiningNutritionFact]

    var hasPublishedContent: Bool {
        ingredients != nil || allergenStatement != nil || !nutrition.isEmpty
    }
}

struct DiningNutritionFact: Codable, Sendable, Equatable {
    let name: String
    let value: String
}

struct MenuMealPeriod: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let sourceOrder: Int
    let sections: [MenuSection]
}

struct MenuSection: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let sourceOrder: Int
    let items: [DiningMenuItem]
}

struct DiningMenuItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let detailURL: URL?
    let sourceOrder: Int
    let sourceLabels: [String]
    let detailMetadata: DiningMenuItemDetailMetadata?

    init(
        id: String,
        displayName: String,
        detailURL: URL?,
        sourceOrder: Int,
        sourceLabels: [String],
        detailMetadata: DiningMenuItemDetailMetadata? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.detailURL = detailURL
        self.sourceOrder = sourceOrder
        self.sourceLabels = sourceLabels
        self.detailMetadata = detailMetadata
    }
}
