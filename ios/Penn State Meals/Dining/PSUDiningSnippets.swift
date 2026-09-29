import AppIntents
import SwiftUI

/// Only the fields needed to render a food row travel with the snippet.
/// Unlike a persistent food entity, this snapshot never needs query resolution.
@available(iOS 26.0, *)
struct PSUFoodSnippetItem: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Dining Food Snapshot"
    @Property(title: "Food Identifier") var foodID: String
    @Property(title: "Name") var name: String
    @Property(title: "Meal") var meal: String
    @Property(title: "Station") var station: String
    @Property(title: "Dietary Labels") var dietaryLabels: [String]
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }

    init() { foodID = ""; name = ""; meal = ""; station = ""; dietaryLabels = [] }
    init(_ record: PSUFoodRecord) {
        foodID = record.id
        name = record.item.displayName
        meal = record.mealName
        station = record.sectionName
        dietaryLabels = record.item.sourceLabels
    }
    var food: PSUFoodEntity? {
        PSUFoodEntity(id: foodID, name: name, meal: meal, station: station, dietaryLabels: dietaryLabels)
    }
}

/// App Intents transports these properties directly, including nested food snapshots.
/// The session identifier scopes interactive updates to this particular card.
@available(iOS 26.0, *)
struct PSUDiningCard: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Dining Result"
    @Property(title: "Session") var sessionID: String
    @Property(title: "Title") var title: String
    @Property(title: "Summary") var summary: String
    @Property(title: "Date") var date: Date
    @Property(title: "Warning") var warning: String?
    @Property(title: "Dining Hall") var hall: PSUDiningHallEntity?
    @Property(title: "Meal") var meal: PSUMealPreference?
    @Property(title: "Available Meals") var availableMeals: [PSUMealPreference]
    @Property(title: "Foods") var foods: [PSUFoodSnippetItem]
    @Property(title: "Selected Food") var openFood: PSUFoodSnippetItem?
    @Property(title: "Summary Lines") var lines: [String]
    @Property(title: "Detail Lines") var detailLines: [String]
    var displayRepresentation: DisplayRepresentation { .init(title: "\(title)", subtitle: "\(summary)") }

    init() {
        sessionID = UUID().uuidString
        title = ""; summary = ""; date = .distantPast
        availableMeals = []; foods = []; lines = []; detailLines = []
    }
    init(title: String, summary: String, date: DateOnly) {
        self.init()
        self.title = title
        self.summary = summary
        self.date = date.date(in: PSUServiceSelection.calendar.timeZone) ?? .distantPast
    }
    static let pageSize = 6
    var pageCount: Int { max(1, (foods.count + Self.pageSize - 1) / Self.pageSize) }
    func page(_ requested: Int) -> ArraySlice<PSUFoodSnippetItem> {
        let page = min(max(0, requested), pageCount - 1)
        return foods.dropFirst(page * Self.pageSize).prefix(Self.pageSize)
    }
    func spokenMenuSummary(records: [PSUFoodRecord]) -> String {
        let day = date.formatted(Date.FormatStyle(date: .long, time: .omitted,
            timeZone: PSUServiceSelection.calendar.timeZone))
        let names = PSUDiningMenuSelection.previewNames(in: records)
        let answer = if names.isEmpty {
            String(localized: "\(title), \(day). \(summary)")
        } else {
            String(localized: "\(title), \(day). \(summary) A preview from \(records[0].sectionName): \(names.formatted(.list(type: .and))).")
        }
        return [answer, warning].compactMap { $0 }.joined(separator: " ")
    }

    static func menu(_ result: PSUActionMenu, hall: PSUDiningHall, records: [PSUFoodRecord]) -> Self {
        let summary: String
        if let meal = result.meal {
            if records.isEmpty, meal.sections.contains(where: { !$0.items.isEmpty }) {
                summary = String(localized: "\(meal.displayName): Open Menu to view serving times.")
            } else if records.isEmpty {
                summary = String(localized: "\(meal.displayName): No foods are published.")
            } else {
                summary = meal.displayName
            }
        } else if result.hours?.isExplicitlyClosed == true {
            summary = String(localized: "Closed. No menu is published.")
        } else {
            summary = String(localized: "No menu is published for the selected meal.")
        }
        let card = Self(title: hall.rawValue.capitalized, summary: summary, date: result.snapshot.key.localDate)
        card.hall = PSUDiningHallEntity(hall)
        card.meal = result.meal.flatMap { PSUMealPreference(rawValue: $0.servicePeriod.id.rawValue) }
        card.availableMeals = result.snapshot.meals.compactMap { PSUMealPreference(rawValue: $0.servicePeriod.id.rawValue) }
        card.foods = records.map(PSUFoodSnippetItem.init)
        if result.isStale { card.warning = String(localized: "Saved menu — refresh unavailable.") }
        return card
    }
}

/// Only control intents write this state. The renderer reads it on the system's
/// automatic refresh, including when rendering and controls run in different processes.
@available(iOS 26.0, *)
struct PSUDiningSnippetState: Codable, Sendable {
    struct Menu: Codable, Sendable {
        let meal: String
        let summary: String
        let warning: String?
        let availableMeals: [String]
        let records: [PSUFoodRecord]
    }
    var page = 0
    var showDetails = false
    var menu: Menu?

    func resolvedCard(fallback: PSUDiningCard) -> PSUDiningCard {
        guard let menu else { return fallback }
        let card = PSUDiningCard()
        card.sessionID = fallback.sessionID
        card.title = fallback.title
        card.date = fallback.date
        card.hall = fallback.hall
        card.summary = menu.summary
        card.warning = menu.warning
        card.meal = PSUMealPreference(rawValue: menu.meal)
        card.availableMeals = menu.availableMeals.compactMap(PSUMealPreference.init(rawValue:))
        card.foods = menu.records.map(PSUFoodSnippetItem.init)
        return card
    }
}

@available(iOS 26.0, *)
actor PSUDiningSnippetStateStore {
    static let shared = PSUDiningSnippetStateStore()
    private let root: URL
    init(root: URL = PSUDiningAccess.root.appending(path: "SnippetState-v1")) { self.root = root }

    func read(sessionID: String) -> PSUDiningSnippetState? {
        guard let file = file(sessionID: sessionID),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PSUDiningSnippetState.self, from: data)
    }

    func setMenu(_ menu: PSUDiningSnippetState.Menu, sessionID: String) throws {
        // Switching meals always starts at the first page of the new menu.
        try write(PSUDiningSnippetState(menu: menu), sessionID: sessionID)
    }

    func setPage(_ page: Int, showDetails: Bool, sessionID: String) throws {
        var state = read(sessionID: sessionID) ?? PSUDiningSnippetState()
        state.page = max(0, page)
        state.showDetails = showDetails
        try write(state, sessionID: sessionID)
    }

    private func file(sessionID: String) -> URL? {
        guard let id = UUID(uuidString: sessionID) else { return nil }
        return root.appending(path: id.uuidString).appendingPathExtension("json")
    }

    private func write(_ state: PSUDiningSnippetState, sessionID: String) throws {
        guard let file = file(sessionID: sessionID) else { throw PSUDiningActionError.invalidSelection }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            // Bound disk usage without mutating anything during snippet rendering.
            let files = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey])
            let dated = files.filter { $0.pathExtension == "json" }.map { url in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }.sorted { $0.1 > $1.1 }
            for (old, _) in dated.dropFirst(64) where old != file { try? FileManager.default.removeItem(at: old) }
        } catch {
            throw PSUDiningSnippetUpdateError.unavailable
        }
    }
}

private enum PSUDiningSnippetUpdateError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable
    var localizedStringResource: LocalizedStringResource { "The dining card could not be updated. Please try again." }
}

/// A meal tap updates the existing card. Returning another snippet would stack a popover.
@available(iOS 26.0, *)
struct SelectPSUDiningSnippetMealIntent: AppIntent {
    static let title: LocalizedStringResource = "Select Dining Meal"
    static var isDiscoverable: Bool { false }
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "Dining Result") var card: PSUDiningCard
    @Parameter(title: "Meal") var meal: PSUMealPreference
    init() {}
    init(card: PSUDiningCard, meal: PSUMealPreference) { self.card = card; self.meal = meal }
    @concurrent func perform() async throws -> some IntentResult {
        guard let hall = card.hall?.hall, card.availableMeals.contains(meal) else {
            throw PSUDiningActionError.invalidSelection
        }
        let state = await PSUDiningSnippetStateStore.shared.read(sessionID: card.sessionID)
        let current = state?.resolvedCard(fallback: card) ?? card
        guard current.meal != meal else { return .result() }
        let result = try await PSUDiningServices.intents.menu(hall: hall,
            date: hall.calendarContext.localDate(containing: card.date), preference: meal.rawValue)
        guard result.meal != nil else { throw PSUDiningActionError.menuNotPublished }
        let records = PSUDiningMenuSelection.records(in: result)
        let updated = PSUDiningCard.menu(result, hall: hall, records: records)
        try Task.checkCancellation()
        try await PSUDiningSnippetStateStore.shared.setMenu(.init(meal: meal.rawValue,
            summary: updated.summary, warning: updated.warning,
            availableMeals: updated.availableMeals.map(\.rawValue), records: records), sessionID: card.sessionID)
        return .result()
    }
}

@available(iOS 26.0, *)
struct PSUDiningSnippet: SnippetIntent {
    static let title: LocalizedStringResource = "Dining Result"
    @Parameter(title: "Dining Result") var card: PSUDiningCard
    @Parameter(title: "Page", default: 0) var page: Int
    @Parameter(title: "Show Details", default: false) var showDetails: Bool
    init() {}
    init(card: PSUDiningCard, page: Int = 0, showDetails: Bool = false) {
        self.card = card; self.page = page; self.showDetails = showDetails
    }
    @concurrent func perform() async throws -> some IntentResult & ShowsSnippetView {
        let state = await PSUDiningSnippetStateStore.shared.read(sessionID: card.sessionID)
        let current = state?.resolvedCard(fallback: card) ?? card
        let currentPage = min(max(0, state?.page ?? page), current.pageCount - 1)
        return .result(view: PSUDiningCardView(card: current, page: currentPage,
                                             showDetails: state?.showDetails ?? showDetails))
    }
}

/// Paging and detail toggles refresh the hosting snippet without presenting a new one.
@available(iOS 26.0, *)
struct ShowPSUDiningPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Dining Details"
    static var isDiscoverable: Bool { false }
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "Dining Result") var card: PSUDiningCard
    @Parameter(title: "Page", default: 0) var page: Int
    @Parameter(title: "Show Details", default: false) var showDetails: Bool
    init() {}
    init(card: PSUDiningCard, page: Int, showDetails: Bool = false) { self.card = card; self.page = page; self.showDetails = showDetails }
    @concurrent func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        let state = await PSUDiningSnippetStateStore.shared.read(sessionID: card.sessionID)
        let current = state?.resolvedCard(fallback: card) ?? card
        try await PSUDiningSnippetStateStore.shared.setPage(min(max(0, page), current.pageCount - 1),
            showDetails: showDetails, sessionID: card.sessionID)
        return .result()
    }
}

@available(iOS 26.0, *)
private struct PSUDiningCardView: View {
    let card: PSUDiningCard
    let page: Int
    let showDetails: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(card.title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(card.summary).font(.subheadline)
            if let warning = card.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption) }
            if card.hall != nil, !card.availableMeals.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack { PSUDiningMealButtons(card: card) }
                    VStack(alignment: .leading) { PSUDiningMealButtons(card: card) }
                }
            }
            ForEach(card.page(page), id: \.foodID) { item in
                if let food = item.food { PSUFoodSnippetRow(food: food) }
            }
            if !card.foods.isEmpty {
                HStack {
                    if page > 0 {
                        Button(intent: ShowPSUDiningPageIntent(card: card, page: page - 1, showDetails: showDetails)) { Label("Previous", systemImage: "chevron.left") }
                    }
                    Text("Page \(page + 1) of \(card.pageCount)").font(.caption)
                    if page + 1 < card.pageCount {
                        Button(intent: ShowPSUDiningPageIntent(card: card, page: page + 1, showDetails: showDetails)) { Label("Next", systemImage: "chevron.right") }
                    }
                }
            }
            // One text block preserves provider ordering and avoids inventing identities for facts.
            let lines = showDetails ? card.detailLines : card.lines
            if !lines.isEmpty { Text(lines.joined(separator: "\n")).font(.subheadline) }
            if !card.detailLines.isEmpty {
                Button(intent: ShowPSUDiningPageIntent(card: card, page: page, showDetails: !showDetails)) {
                    if showDetails { Text("Nutrition Summary") } else { Text("All Facts, Ingredients & Allergens") }
                }
            }
            if let food = card.openFood?.food {
                Button(intent: OpenPSUFoodIntent(food: food)) { Label("Open Food", systemImage: "arrow.up.forward.app") }
            } else if let hall = card.hall?.hall {
                Button(intent: OpenPSUDiningMenuIntent(hall: hall, date: card.date,
                    meal: card.meal ?? .automatic)) {
                    Label("Open Menu", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

@available(iOS 26.0, *)
private struct PSUDiningMealButtons: View {
    let card: PSUDiningCard
    var body: some View {
        ForEach(card.availableMeals, id: \.self) { preference in
            Button(intent: SelectPSUDiningSnippetMealIntent(card: card, meal: preference)) {
                Text(preference.localizedTitle)
                    .fontWeight(card.meal == preference ? .semibold : .regular)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(card.meal == preference ? Color.white : Color.primary)
                    .background(card.meal == preference ? Color.accentColor : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(card.meal == preference ? .isSelected : [])
        }
    }
}

@available(iOS 26.0, *)
private struct PSUFoodSnippetRow: View {
    let food: PSUFoodEntity
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(food.name).font(.body).bold()
            HStack {
                if !food.station.isEmpty { Text(food.station).font(.caption).foregroundStyle(.secondary) }
                Button(intent: GetPSUNutritionIntent(food: food)) { Label("Nutrition", systemImage: "carrot") }
                    .accessibilityLabel("Nutrition for \(food.name)")
            }
        }.appEntityIdentifier(EntityIdentifier(for: food))
    }
}

extension PSUMealPreference {
    var localizedTitle: LocalizedStringResource {
        switch self {
        case .automatic: "Automatic"
        case .breakfast: "Breakfast"
        case .brunch: "Brunch"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .lateNight: "Late Night"
        }
    }
}
