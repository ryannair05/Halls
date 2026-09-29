import AppIntents
import Foundation

@available(iOS 26.0, *)
struct PSUNutritionResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Food Nutrition"
    @Property(title: "Food") var food: PSUFoodEntity?
    @Property(title: "Serving Size") var servingSize: String?
    @Property(title: "Calories (kcal)") var calories: Double?
    @Property(title: "Protein (g)") var protein: Double?
    @Property(title: "Carbohydrates (g)") var carbohydrates: Double?
    @Property(title: "Fat (g)") var fat: Double?
    @Property(title: "Ingredients") var ingredients: String?
    @Property(title: "Allergens") var allergens: String?
    @Property(title: "Published Facts") var publishedFacts: [String]
    @Property(title: "Information Published") var isPublished: Bool
    var displayRepresentation: DisplayRepresentation { .init(title: "Nutrition", subtitle: "\(food?.name ?? "")") }
    init() { publishedFacts = []; isPublished = false }
    init(food: PSUFoodEntity, detail: PSUMenuItemDetail?) {
        self.init()
        self.food = food
        guard let detail else { return }
        isPublished = true
        ingredients = detail.ingredients
        allergens = detail.allergenStatement
        let facts = detail.nutrition ?? []
        servingSize = facts.first { DiningTextNormalizer.foldedWords($0.name) == "serving size" }?.value
        calories = Self.amount(in: facts, name: "calories", calories: true)
        protein = Self.amount(in: facts, name: "protein")
        carbohydrates = Self.amount(in: facts, name: "total carbohydrate")
        fat = Self.amount(in: facts, name: "total fat")
        publishedFacts = facts.map { "\($0.name): \($0.value)" }
    }
    static func amount(in facts: [DiningNutritionFact], name: String, calories: Bool = false) -> Double? {
        guard let fact = facts.first(where: { DiningTextNormalizer.foldedWords($0.name) == name }) else { return nil }
        let text = String(fact.value.prefix { $0 != "·" }).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Do not reinterpret inequalities, percentages, or unknown units as exact amounts.
        let pieces = text.split(whereSeparator: { $0.isWhitespace })
        let compact = pieces.joined()
        let digits = compact.prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let amount = Double(digits), amount.isFinite, amount >= 0 else { return nil }
        let unit = String(compact.dropFirst(digits.count))
        if calories { return ["", "kcal", "cal", "calories"].contains(unit) ? amount : nil }
        return switch unit {
        case "g": amount
        case "mg": amount / 1_000
        case "mcg", "µg": amount / 1_000_000
        default: nil
        }
    }
}

@available(iOS 26.0, *)
struct PSUDiningHoursIntervalEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Dining Interval"
    @Property(title: "Service") var service: String
    @Property(title: "Opens") var opens: Date
    @Property(title: "Closes") var closes: Date
    var displayRepresentation: DisplayRepresentation { .init(title: "\(service)") }
    init() { service = ""; opens = .distantPast; closes = .distantPast }
    init(service: String, opens: Date, closes: Date) { self.service = service; self.opens = opens; self.closes = closes }
}

@available(iOS 26.0, *)
enum PSUSearchMeal: String, AppEnum {
    case all, breakfast, brunch, lunch, dinner
    case lateNight = "late-night"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meal"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .all: "All Meals", .breakfast: "Breakfast", .brunch: "Brunch", .lunch: "Lunch", .dinner: "Dinner", .lateNight: "Late Night"
    ]
}
