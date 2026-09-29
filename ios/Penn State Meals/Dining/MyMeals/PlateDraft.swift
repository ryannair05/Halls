import Foundation
import Observation

struct PlateContext: Equatable, Sendable {
    let hall: PSUDiningHall
    let date: DateOnly
    let mealName: String

    var title: String { "\(hall.rawValue.capitalized) · \(mealName)" }
    var dateLabel: String {
        guard let date = date.date(in: ProviderCalendarContexts.pennState.timeZone) else { return self.date.description }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: ProviderCalendarContexts.pennState.timeZone))
    }
}

enum PlateNutritionState: Equatable, Sendable {
    case pending, loading, loaded, unavailable, failed
}

struct PlateDraftItem: Identifiable, Equatable, Sendable {
    let id: String
    let token: UUID
    let name: String
    var source: DiningMenuItem?
    var servings: Double
    var facts: [DiningNutritionFact]
    var allergenStatement: String?
    var nutritionState: PlateNutritionState

    var servingSize: String? {
        facts.first { DiningTextNormalizer.foldedWords($0.name) == "serving size" }?.value
    }
    var totals: NutritionTotals {
        var totals = NutritionTotals()
        totals.add(NutritionNormalizer.normalize(facts), servings: servings)
        return totals
    }
}

@Observable @MainActor
final class PlateDraft {
    let context: PlateContext
    var recordID: UUID?
    var items: [PlateDraftItem] {
        didSet { updateSummary(previous: oldValue) }
    }
    private(set) var totals = NutritionTotals()
    private(set) var allergenStatements: [String] = []
    private(set) var isLoading = false
    @ObservationIgnored private var nutritionGeneration = UUID()

    init(context: PlateContext, record: MealRecord? = nil) {
        self.context = context
        recordID = record?.id
        items = record?.items.map {
            PlateDraftItem(
                id: $0.sourceItemID, token: UUID(), name: $0.displayName, source: nil,
                servings: $0.servingMultiplier,
                facts: $0.nutritionFacts.map { DiningNutritionFact(name: $0.name, value: $0.value) },
                allergenStatement: $0.allergenStatement, nutritionState: .loaded
            )
        } ?? []
        updateSummary()
    }

    private func updateSummary(previous: [PlateDraftItem]? = nil) {
        let sameCount = previous?.count == items.count
        // Loader state changes don't require re-normalizing every food's nutrition.
        if !sameCount || zip(previous ?? [], items).contains(where: {
            $0.servings != $1.servings || $0.facts != $1.facts
        }) {
            totals = items.reduce(into: NutritionTotals()) { $0.merge($1.totals) }
        }
        if !sameCount || zip(previous ?? [], items).contains(where: {
            $0.allergenStatement != $1.allergenStatement
        }) {
            allergenStatements = Array(Set(items.compactMap(\.allergenStatement))).sorted()
        }
        isLoading = items.contains { $0.nutritionState == .pending || $0.nutritionState == .loading }
    }
    func contains(_ item: DiningMenuItem) -> Bool { items.contains { $0.id == item.id } }

    func add(_ item: DiningMenuItem) {
        guard !contains(item) else { return }
        items.append(PlateDraftItem(
            id: item.id, token: UUID(), name: item.displayName, source: item,
            servings: 1, facts: [], allergenStatement: nil, nutritionState: .pending
        ))
    }
    func remove(_ id: String) { items.removeAll { $0.id == id } }

    func retryNutrition() {
        for index in items.indices where items[index].nutritionState == .failed {
            items[index].nutritionState = .pending
        }
    }

    func loadNutrition(environment: DiningMenuEnvironment) async {
        await loadNutrition { @concurrent item, context in
            await Self.fetch(item, context: context, environment: environment)
        }
    }

    func loadNutrition(using loader: @escaping @Sendable @concurrent (DiningMenuItem, PlateContext) async -> PlateNutritionResult) async {
        let generation = UUID()
        nutritionGeneration = generation
        let requests = items.filter { ($0.nutritionState == .pending || $0.nutritionState == .loading) && $0.source != nil }
        for item in requests {
            if let index = items.firstIndex(where: { $0.token == item.token }) {
                items[index].nutritionState = .loading
            }
        }
        let context = context
        await withTaskGroup(of: (UUID, PlateNutritionResult).self) { group in
            var iterator = requests.makeIterator()
            func enqueue(_ item: PlateDraftItem) {
                guard let source = item.source else { return }
                group.addTask { @concurrent in
                    (item.token, await loader(source, context))
                }
            }
            for _ in 0..<4 {
                if let next = iterator.next() { enqueue(next) }
            }
            for await (token, result) in group {
                guard !Task.isCancelled, nutritionGeneration == generation else { group.cancelAll(); break }
                if let index = items.firstIndex(where: { $0.token == token }) {
                    var item = items[index]
                    item.facts = result.facts
                    item.allergenStatement = result.allergens
                    item.nutritionState = result.state
                    items[index] = item
                }
                if let next = iterator.next() { enqueue(next) }
            }
        }
        if Task.isCancelled, nutritionGeneration == generation {
            for item in requests {
                if let index = items.firstIndex(where: { $0.token == item.token }), items[index].nutritionState == .loading {
                    items[index].nutritionState = .pending
                }
            }
        }
    }

    @concurrent
    private static func fetch(_ item: DiningMenuItem, context: PlateContext, environment: DiningMenuEnvironment) async -> PlateNutritionResult {
        guard item.detailURL != nil || item.detailMetadata != nil else {
            return PlateNutritionResult(facts: [], allergens: nil, state: .unavailable)
        }
        do {
            let state = try await environment.itemDetail(for: item, context: context)
            switch state {
            case .available(let detail):
                return PlateNutritionResult(facts: detail.nutrition ?? [], allergens: detail.allergenStatement, state: .loaded)
            case .unavailable:
                return PlateNutritionResult(facts: [], allergens: nil, state: .unavailable)
            case .parseFailed:
                return PlateNutritionResult(facts: [], allergens: nil, state: .failed)
            }
        } catch {
            return PlateNutritionResult(facts: [], allergens: nil, state: .failed)
        }
    }
}

struct PlateNutritionResult: Sendable {
    let facts: [DiningNutritionFact]
    let allergens: String?
    let state: PlateNutritionState
}
