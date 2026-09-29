import AppIntents
import Foundation
import OSLog

/// Serializes real UI donations with campus changes so disabled PSU actions cannot linger.
@available(iOS 26.0, *)
actor PSUDiningSuggestions {
    static let shared = PSUDiningSuggestions()
    private var pending: Task<Void, Never>?

    func update(_ intent: OpenPSUDiningMenuIntent? = nil) async {
        let preceding = pending
        let task = Task { @concurrent in
            await preceding?.value
            do {
                if PSUDiningAccess.isEnabled, let intent {
                    try await IntentDonationManager.shared.donate(intent: intent)
                }
                // Recheck after the donation suspension point.
                if !PSUDiningAccess.isEnabled {
                    try await IntentDonationManager.shared.deleteDonations(
                        matching: .intentType(OpenPSUDiningMenuIntent.self))
                }
            } catch {
                Logger(subsystem: "com.ryannair05.pennstatemeals", category: "DiningSuggestions")
                    .error("Menu suggestion update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        pending = task
        await task.value
    }
}

@available(iOS 26.0, *)
struct GetPSUDiningMenuIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Menu"
    static let description = IntentDescription("Get foods from dining hall sections without specific serving times. Pass the foods to Get Nutrition or Open Food.")
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "Dining Hall", requestDisambiguationDialog: "Which dining hall's menu would you like?")
    var diningHall: PSUDiningHall
    @Parameter(title: "Date") var date: Date?
    @Parameter(title: "Meal", default: .automatic) var meal: PSUMealPreference
    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$meal) at \(\.$diningHall)") { \.$date } }
    init() {}
    init(hall: PSUDiningHall, date: Date?, meal: PSUMealPreference = .automatic) {
        diningHall = hall; self.date = date; self.meal = meal
    }
    @concurrent func perform() async throws -> some IntentResult & ReturnsValue<[PSUFoodEntity]> & ProvidesDialog & ShowsSnippetIntent {
        let hall = diningHall
        let result = try await PSUDiningServices.intents.menu(hall: hall, date: PSUServiceSelection.calendar.localDate(containing: date ?? .now), preference: meal.rawValue)
        let records = PSUDiningMenuSelection.records(in: result)
        let card = PSUDiningCard.menu(result, hall: hall, records: records)
        return .result(value: records.map(PSUFoodEntity.init), dialog: "\(card.spokenMenuSummary(records: records))",
                       snippetIntent: PSUDiningSnippet(card: card))
    }
}

@available(iOS 26.0, *)
struct FindPSUFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Food"
    static let description = IntentDescription("Find a food across PSU dining halls, or optionally choose one hall.")
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "Food Name", requestValueDialog: "What food would you like to find?") var searchText: String
    @Parameter(title: "Dining Hall") var diningHall: PSUDiningHall?
    @Parameter(title: "Date") var date: Date?
    @Parameter(title: "Meal", default: .all) var meal: PSUSearchMeal
    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$searchText)") { \.$diningHall; \.$date; \.$meal }
    }
    @concurrent func perform() async throws -> some IntentResult & ReturnsValue<[PSUFoodEntity]> & ProvidesDialog & ShowsSnippetIntent {
        guard !DiningTextNormalizer.foldedWords(searchText).isEmpty else {
            throw $searchText.needsValueError("What food would you like to find?")
        }
        let day = PSUServiceSelection.calendar.localDate(containing: date ?? .now)
        let result = try await PSUDiningServices.intents.search(text: searchText, date: day,
            hall: diningHall, meal: meal == .all ? nil : meal.rawValue)
        let halls = Array(Set(result.records.map(\.hallName))).sorted().formatted(.list(type: .and))
        let summary = if result.records.isEmpty {
            String(localized: "No matching foods were found.")
        } else {
            String(localized: "Found \(result.records.count) servings at \(halls).")
        }
        let dayName = (day.date(in: PSUServiceSelection.calendar.timeZone) ?? .now)
            .formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: PSUServiceSelection.calendar.timeZone))
        let mealName = meal == .all ? String(localized: "All meals") : meal.rawValue.replacingOccurrences(of: "-", with: " ").capitalized
        let card = PSUDiningCard(title: searchText, summary: "\(dayName) · \(mealName). \(summary)", date: day)
        card.foods = result.records.map(PSUFoodSnippetItem.init)
        if !result.failedHalls.isEmpty {
            card.warning = String(localized: "Some menus could not be refreshed: \(result.failedHalls.formatted(.list(type: .and))).")
        }
        return .result(value: result.records.map(PSUFoodEntity.init),
            dialog: "\(card.summary) \(card.warning ?? "")", snippetIntent: PSUDiningSnippet(card: card))
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct SearchPSUFoodInAppIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Dining Menus"
    static let description = IntentDescription("Search today's PSU menus in Halls.")
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static var searchScopes: [StringSearchScope] { [.general] }
    @Parameter(title: "Food Name") var criteria: StringSearchCriteria

    static func validatedQuery(_ text: String) -> String? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.count >= 3 && !DiningTextNormalizer.foldedWords(query).isEmpty ? query : nil
    }

    @concurrent func perform() async throws -> some IntentResult {
        guard let query = Self.validatedQuery(criteria.term) else {
            throw $criteria.needsValueError("What food would you like to find? Use at least three characters.")
        }
        try Task.checkCancellation()
        await PSUDiningIntentNavigation.open(.foodSearch(query))
        return .result()
    }
}

@available(iOS 26.0, *)
struct GetPSUNutritionIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Nutrition"
    static let description = IntentDescription("Get published serving size, nutrients, ingredients, and allergens for a food.")
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "Food") var food: PSUFoodEntity
    static var parameterSummary: some ParameterSummary { Summary("Get nutrition for \(\.$food)") }
    init() {}
    init(food: PSUFoodEntity) { self.food = food }
    @concurrent func perform() async throws -> some IntentResult & ReturnsValue<PSUNutritionResult> & ProvidesDialog & ShowsSnippetIntent {
        guard let reference = PSUFoodReference(id: food.id) else { throw PSUDiningActionError.foodUnavailable }
        let record = try await PSUDiningServices.intents.resolve(reference)
        let detail: PSUMenuItemDetail?
        do {
            switch try await PSUDiningServices.intents.nutrition(for: record) {
            case .available(let published): detail = published
            case .unavailable: detail = nil
            case .parseFailed: throw PSUDiningActionError.nutritionUnavailable
            }
        } catch PSUDiningActionError.nutritionNotPublished { detail = nil }
        let value = PSUNutritionResult(food: PSUFoodEntity(record), detail: detail)
        let card = PSUDiningCard(title: record.item.displayName,
                                summary: detail == nil ? String(localized: "Nutrition information is not published.") : String(localized: "Published nutrition per serving."),
                                date: reference.date)
        card.hall = value.food?.diningHall
        card.meal = PSUMealPreference(rawValue: reference.mealID)
        card.openFood = PSUFoodSnippetItem(record)
        card.lines = (detail?.nutrition ?? []).filter {
            ["serving size", "calories", "protein", "total carbohydrate", "total fat"].contains(DiningTextNormalizer.foldedWords($0.name))
        }.map { "\($0.name): \($0.value)" }
        if let detail { card.detailLines = (detail.nutrition ?? []).map { "\($0.name): \($0.value)" } + [
            String(localized: "Ingredients: \(detail.ingredients ?? String(localized: "Not published"))"),
            String(localized: "Allergens: \(detail.allergenStatement ?? String(localized: "Not published"))")
        ] }
        return .result(value: value, dialog: "\(record.item.displayName). \(card.summary) \(card.lines.joined(separator: "; "))", snippetIntent: PSUDiningSnippet(card: card))
    }
}

@available(iOS 26.0, *)
struct OpenPSUDiningMenuIntent: AppIntent, PredictableIntent {
    static let title: LocalizedStringResource = "Open Dining Hall"
    static var supportedModes: IntentModes { .foreground }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Dining Hall") var target: PSUDiningHall?
    @Parameter(title: "Date") var date: Date?
    @Parameter(title: "Meal") var meal: PSUMealPreference?
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") { \.$date; \.$meal } }
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$target, \.$meal, \.$date)) { hall, meal, date in
            let name = hall?.rawValue.capitalized ?? "PSU"
            let mealName = (meal ?? .automatic).rawValue.replacingOccurrences(of: "-", with: " ").capitalized
            let detail = if let date {
                date.formatted(date: .abbreviated, time: .omitted)
            } else if meal == nil || meal == .automatic {
                String(localized: "Today's menu")
            } else {
                String(localized: "\(mealName) menu")
            }
            return DisplayRepresentation(title: "\(name) Dining Hall", subtitle: "\(detail)",
                                         image: .init(systemName: "fork.knife"))
        }
    }
    init() {}
    init(hall: PSUDiningHall, date: Date?, meal: PSUMealPreference = .automatic) { target = hall; self.date = date; self.meal = meal }
    @concurrent func perform() async throws -> some IntentResult {
        try PSUDiningAccess.requireEnabled()
        guard let target else {
            try Task.checkCancellation()
            await PSUDiningIntentNavigation.open(.diningHome)
            return .result()
        }
        let hall = target
        let day = PSUServiceSelection.calendar.localDate(containing: date ?? .now)
        guard hall.calendarContext.contains(day, relativeTo: .now) else { throw PSUDiningActionError.dateUnavailable }
        try Task.checkCancellation()
        await PSUDiningIntentNavigation.open(.hall(hall.rawValue, date: day, meal: meal.flatMap { $0 == .automatic ? nil : DiningDeepLinkMeal(rawValue: $0.rawValue) }))
        return .result()
    }
}

/// The system open schema requires a concrete entity; the optional-hall action also opens the list.
@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenPSUDiningHallEntityIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Dining Hall"
    static var isAssistantOnly: Bool { true }
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Dining Hall") var target: PSUDiningHallEntity

    @concurrent func perform() async throws -> some IntentResult {
        guard let hall = target.hall else { throw PSUDiningActionError.invalidSelection }
        return try await OpenPSUDiningMenuIntent(hall: hall, date: nil).perform()
    }
}

@available(iOS 26.0, *)
struct OpenPSUFoodIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Food"
    static var supportedModes: IntentModes { .foreground }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Food") var target: PSUFoodEntity
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }
    init() {}
    init(food: PSUFoodEntity) { target = food }
    @concurrent func perform() async throws -> some IntentResult {
        guard let reference = PSUFoodReference(id: target.id) else { throw PSUDiningActionError.foodUnavailable }
        guard PSUServiceSelection.calendar.contains(reference.date, relativeTo: .now) else { throw PSUDiningActionError.dateUnavailable }
        try Task.checkCancellation()
        await PSUDiningIntentNavigation.open(.food(reference))
        return .result()
    }
}
