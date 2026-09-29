import Foundation
import Observation
import SwiftData
import UserNotifications

enum MealRecordStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case eaten
}

struct StoredNutritionFact: Codable, Hashable, Sendable {
    let name: String
    let value: String
}

struct NormalizedNutrient: Codable, Hashable, Sendable {
    let name: String
    let amount: Double
    let unit: String
}

enum PlateNutrient: String, CaseIterable, Sendable {
    case calories, protein, carbohydrates, fat

    var title: String {
        switch self {
        case .calories: "Calories"
        case .protein: "Protein"
        case .carbohydrates: "Carbs"
        case .fat: "Fat"
        }
    }
    var unit: String { self == .calories ? "kcal" : "g" }
    var sourceName: String {
        switch self {
        case .calories: "calories"
        case .protein: "protein"
        case .carbohydrates: "total carbohydrate"
        case .fat: "total fat"
        }
    }
}

struct NutritionTotals: Sendable, Equatable {
    private var amounts: [PlateNutrient: Double] = [:]
    private var coverage: [PlateNutrient: Int] = [:]
    private(set) var itemCount = 0

    func amount(_ nutrient: PlateNutrient) -> Double? { amounts[nutrient] }
    func isPartial(_ nutrient: PlateNutrient) -> Bool {
        (coverage[nutrient] ?? 0) < itemCount
    }
    var isComplete: Bool { itemCount > 0 && PlateNutrient.allCases.allSatisfy { !isPartial($0) } }

    func text(_ nutrient: PlateNutrient) -> String {
        guard let amount = amount(nutrient) else { return "Unavailable" }
        let value = amount.formatted(.number.precision(.fractionLength(0...1)))
        return "\(value) \(nutrient.unit)" + (isPartial(nutrient) ? " · Partial" : "")
    }

    mutating func merge(_ other: Self) {
        itemCount += other.itemCount
        for nutrient in PlateNutrient.allCases {
            if let value = other.amounts[nutrient] { amounts[nutrient, default: 0] += value }
            coverage[nutrient, default: 0] += other.coverage[nutrient, default: 0]
        }
    }

    mutating func add(_ nutrients: [NormalizedNutrient], servings: Double) {
        itemCount += 1
        guard servings.isFinite, servings > 0 else { return }
        for nutrient in PlateNutrient.allCases {
            guard let fact = nutrients.first(where: { $0.name == nutrient.sourceName }),
                  fact.amount.isFinite, fact.amount >= 0 else { continue }
            let scale: Double
            switch (nutrient, fact.unit) {
            case (.calories, "kcal"): scale = 1
            case (.calories, _): continue
            case (_, "g"): scale = 1
            case (_, "mg"): scale = 0.001
            case (_, "mcg"), (_, "µg"): scale = 0.000001
            default: continue
            }
            let amount = fact.amount * scale * servings
            guard amount.isFinite else { continue }
            amounts[nutrient, default: 0] += amount
            coverage[nutrient, default: 0] += 1
        }
    }
}

enum NutritionNormalizer {
    // Anchor the complete measurement: percentages, inequalities and arbitrary text aren't grams.
    private static let measurement = try! NSRegularExpression(
        pattern: #"^([0-9]+(?:\.[0-9]+)?)\s*(kcal|calories|cal|mg|mcg|µg|g)?$"#,
        options: [.caseInsensitive]
    )

    static func normalize(_ facts: [DiningNutritionFact]) -> [NormalizedNutrient] {
        var seen = Set<String>()
        return facts.compactMap { fact in
            let name = canonicalName(fact.name)
            guard PlateNutrient.allCases.contains(where: { $0.sourceName == name }),
                  !seen.contains(name) else { return nil }
            let value = String(fact.value.prefix { $0 != "·" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = measurement.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let amountRange = Range(match.range(at: 1), in: value),
                  let amount = Double(value[amountRange]), amount.isFinite else { return nil }
            let unit = Range(match.range(at: 2), in: value).map { String(value[$0]).lowercased() } ?? ""
            let normalizedUnit: String
            if name == "calories" {
                guard ["", "kcal", "cal", "calories"].contains(unit) else { return nil }
                normalizedUnit = "kcal"
            } else {
                guard ["g", "mg", "mcg", "µg"].contains(unit) else { return nil }
                normalizedUnit = unit
            }
            seen.insert(name)
            return NormalizedNutrient(name: name, amount: amount, unit: normalizedUnit)
        }
    }

    private static func canonicalName(_ source: String) -> String {
        switch DiningTextNormalizer.foldedWords(source) {
        case "calorie", "calories": "calories"
        case "fat", "total fat": "total fat"
        case "carb", "carbs", "total carb", "total carbs", "carbohydrate", "carbohydrates",
             "total carbohydrate", "total carbohydrates": "total carbohydrate"
        case "protein": "protein"
        default: ""
        }
    }
}

@Model
final class MealItemRecord {
    @Attribute(.unique) var id: UUID
    var sourceItemID: String
    var displayName: String
    var servingSize: String?
    var servingMultiplier: Double
    var nutritionAvailable: Bool
    var nutritionFactsData: Data
    var normalizedNutrientsData: Data
    var allergenStatement: String?
    var meal: MealRecord?

    init(
        id: UUID = UUID(),
        sourceItemID: String,
        displayName: String,
        servingSize: String?,
        servingMultiplier: Double = 1,
        nutritionFacts: [DiningNutritionFact],
        allergenStatement: String?
    ) {
        self.id = id
        self.sourceItemID = sourceItemID
        self.displayName = displayName
        self.servingSize = servingSize
        self.servingMultiplier = servingMultiplier
        self.nutritionAvailable = !nutritionFacts.isEmpty
        self.nutritionFactsData = Self.encode(
            nutritionFacts.map { StoredNutritionFact(name: $0.name, value: $0.value) }
        )
        self.normalizedNutrientsData = Self.encode(NutritionNormalizer.normalize(nutritionFacts))
        self.allergenStatement = allergenStatement
    }

    var nutritionFacts: [StoredNutritionFact] {
        Self.decode([StoredNutritionFact].self, from: nutritionFactsData) ?? []
    }

    var normalizedNutrients: [NormalizedNutrient] {
        NutritionNormalizer.normalize(nutritionFacts.map { DiningNutritionFact(name: $0.name, value: $0.value) })
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

@Model
final class MealRecord {
    @Attribute(.unique) var id: UUID
    var statusRawValue: String
    var hallRawValue: String
    var menuDateValue: String
    var servicePeriodName: String
    var scheduledAt: Date?
    var reminderIdentifier: String?
    var createdAt: Date
    var updatedAt: Date
    var eatenAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \MealItemRecord.meal)
    var items: [MealItemRecord]

    init(
        id: UUID = UUID(),
        status: MealRecordStatus,
        hall: PSUDiningHall,
        menuDate: DateOnly,
        servicePeriodName: String,
        scheduledAt: Date? = nil,
        items: [MealItemRecord]
    ) {
        self.id = id
        self.statusRawValue = status.rawValue
        self.hallRawValue = hall.rawValue
        self.menuDateValue = menuDate.description
        self.servicePeriodName = servicePeriodName
        self.scheduledAt = scheduledAt
        self.createdAt = .now
        self.updatedAt = .now
        self.eatenAt = status == .eaten ? .now : nil
        self.items = items
        for item in items { item.meal = self }
    }

    var status: MealRecordStatus {
        get { MealRecordStatus(rawValue: statusRawValue) ?? .planned }
        set { statusRawValue = newValue.rawValue }
    }

    var hall: PSUDiningHall? { PSUDiningHall(rawValue: hallRawValue) }
    var menuDate: DateOnly? { DateOnly(deepLinkValue: menuDateValue) }

    var nutritionTotals: NutritionTotals {
        items.reduce(into: NutritionTotals()) { totals, item in
            totals.add(item.normalizedNutrients, servings: item.servingMultiplier)
        }
    }
}

@Observable @MainActor
final class MealJournal {
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var context: ModelContext?
    private let configuration: ModelConfiguration
    private let saveChanges: @MainActor (ModelContext) throws -> Void
    private let reminders: any MealReminderService
    var activeDraft: PlateDraft?
    private(set) var savedRecords: [MealRecord] = []
    private(set) var storageError: String?
    private(set) var reminderError: String?
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?

    init(
        inMemory: Bool = false,
        configuration: ModelConfiguration? = nil,
        reminders: any MealReminderService = MealReminderScheduler(),
        saveChanges: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.configuration = configuration ?? ModelConfiguration(isStoredInMemoryOnly: inMemory)
        self.reminders = reminders
        self.saveChanges = saveChanges
        retryStorage()
    }

    func retryStorage() {
        do {
            if context == nil {
                let container = try ModelContainer(
                    for: MealRecord.self, MealItemRecord.self,
                    configurations: configuration
                )
                self.container = container
                let context = ModelContext(container)
                context.autosaveEnabled = false
                self.context = context
            }
            try reload()
            storageError = nil
        } catch {
            storageError = "Your saved meals couldn’t be opened. Try again. \(error.localizedDescription)"
        }
    }

    private func reload() throws {
        guard let context else { throw JournalError.unavailable }
        savedRecords = try context.fetch(FetchDescriptor<MealRecord>(
            sortBy: [SortDescriptor(\MealRecord.updatedAt, order: .reverse)]
        ))
    }

    func records(status: MealRecordStatus) -> [MealRecord] { savedRecords.filter { $0.status == status } }
    func record(id: UUID) -> MealRecord? { savedRecords.first { $0.id == id } }
    var hasSavedData: Bool { !savedRecords.isEmpty }

    // No notification side effects occur until the complete record is durable.
    @discardableResult
    func commit(
        draft: PlateDraft, status: MealRecordStatus, consumedAt: Date,
        scheduledAt: Date?, reminderEnabled: Bool
    ) throws -> MealRecord {
        guard let context, storageError == nil else { throw JournalError.unavailable }
        guard !draft.items.isEmpty, !draft.isLoading else { throw JournalError.loading }
        guard status != .eaten || consumedAt <= .now else { throw JournalError.futureConsumption }
        let existing = draft.recordID.flatMap(record(id:))
        if draft.recordID != nil && existing == nil { throw JournalError.missing }
        let oldReminder = existing?.reminderIdentifier
        do {
            let items = draft.items.map { item in
                MealItemRecord(
                    sourceItemID: item.id, displayName: item.name, servingSize: item.servingSize,
                    servingMultiplier: item.servings, nutritionFacts: item.facts,
                    allergenStatement: item.allergenStatement
                )
            }
            let target = existing ?? MealRecord(
                status: status, hall: draft.context.hall, menuDate: draft.context.date,
                servicePeriodName: draft.context.mealName, items: []
            )
            if existing == nil { context.insert(target) }
            for item in target.items { context.delete(item) }
            target.items = items
            for item in items { item.meal = target }
            target.status = status
            target.eatenAt = status == .eaten ? consumedAt : nil
            target.scheduledAt = status == .planned ? scheduledAt : nil
            target.updatedAt = .now
            // Persist reminder intent so a failed scheduling attempt can be retried after launch.
            target.reminderIdentifier = status == .planned && reminderEnabled && scheduledAt != nil
                ? MealReminderScheduler.identifier(for: target.id) : nil
            context.processPendingChanges()
            try saveChanges(context)
            draft.recordID = target.id
            refreshAfterSave()
            if let oldReminder { reminders.cancel(oldReminder) }
            return target
        } catch {
            context.rollback()
            throw error
        }
    }

    func cancelReminder(_ record: MealRecord) throws {
        guard let context, storageError == nil else { throw JournalError.unavailable }
        let identifier = record.reminderIdentifier
        record.reminderIdentifier = nil
        do {
            context.processPendingChanges()
            try saveChanges(context)
            refreshAfterSave()
            if let identifier { reminders.cancel(identifier) }
        } catch {
            context.rollback()
            throw error
        }
    }

    func delete(_ record: MealRecord) throws {
        guard let context, storageError == nil else { throw JournalError.unavailable }
        let identifier = record.reminderIdentifier
        context.delete(record)
        do {
            context.processPendingChanges()
            try saveChanges(context)
            refreshAfterSave()
            if let identifier { reminders.cancel(identifier) }
        } catch {
            context.rollback()
            throw error
        }
    }

    private func refreshAfterSave() {
        do { try reload() }
        catch { storageError = "Your meal was saved, but the list couldn’t be refreshed. Try again." }
    }

    func reconcileReminders(requestPermission: Bool = false) async {
        let previous = reconciliationTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.storageError == nil else { return }
            await self.performReconciliation(requestPermission: requestPermission)
        }
        reconciliationTask = task
        await task.value
    }

    private func performReconciliation(requestPermission: Bool) async {
        reminderError = nil
        let pending = await reminders.pendingIdentifiers()
        let requests = savedRecords.compactMap(MealReminderRequest.init)
        let wanted = Set(requests.map(\.identifier))
        for identifier in pending where !wanted.contains(identifier) { reminders.cancel(identifier) }
        for request in requests {
            // Re-read intent before and after every suspension; a record can be edited or deleted.
            guard record(id: request.recordID).flatMap(MealReminderRequest.init) == request else { continue }
            do {
                try await reminders.schedule(request, requestPermission: requestPermission)
                if record(id: request.recordID).flatMap(MealReminderRequest.init) != request {
                    reminders.cancel(request.identifier)
                }
            } catch {
                if record(id: request.recordID).flatMap(MealReminderRequest.init) == request {
                    reminderError = "Your meal is saved, but its reminder couldn’t be set. \(error.localizedDescription)"
                }
            }
        }
    }

    enum JournalError: LocalizedError {
        case unavailable, loading, futureConsumption, missing
        var errorDescription: String? {
            switch self {
            case .unavailable: "Saved meals are unavailable. Reopen My Meals and try again."
            case .loading: "Wait for nutrition to finish loading before saving."
            case .futureConsumption: "The consumed time cannot be in the future."
            case .missing: "This meal has been deleted."
            }
        }
    }
}

struct MealReminderRequest: Equatable, Sendable {
    let recordID: UUID
    let identifier: String
    let date: Date
    let hallName: String
    let mealName: String

    @MainActor
    init?(_ record: MealRecord) {
        guard record.status == .planned, let identifier = record.reminderIdentifier,
              let date = record.scheduledAt, date > .now else { return nil }
        self.recordID = record.id
        self.identifier = identifier
        self.date = date
        hallName = record.hallRawValue.capitalized
        mealName = record.servicePeriodName
    }
}

@MainActor
protocol MealReminderService {
    func pendingIdentifiers() async -> [String]
    func schedule(_ request: MealReminderRequest, requestPermission: Bool) async throws
    func cancel(_ identifier: String)
}

@MainActor
struct MealReminderScheduler: MealReminderService {
    func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().filter {
            $0.content.categoryIdentifier == Self.categoryIdentifier
        }.map(\.identifier)
    }

    static let categoryIdentifier = "MEAL_PLAN_REMINDER"
    static let recordIDKey = "mealRecordID"

    static func identifier(for id: UUID) -> String { "meal-plan-\(id.uuidString)" }

    func schedule(_ request: MealReminderRequest, requestPermission: Bool) async throws {
        let date = request.date
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard requestPermission else { throw ReminderError.permissionDenied }
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { throw ReminderError.permissionDenied }
        } else if settings.authorizationStatus == .denied {
            throw ReminderError.permissionDenied
        }
        guard date > .now else { throw ReminderError.dateInPast }

        let identifier = request.identifier
        let content = UNMutableNotificationContent()
        content.title = "Planned meal at \(request.hallName)"
        content.body = "Your \(request.mealName.lowercased()) plan is ready."
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.recordIDKey: request.recordID.uuidString]
        let context = ProviderCalendarContexts.pennState
        var components = context.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        components.timeZone = context.timeZone
        try await center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        ))
    }

    func cancel(_ identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier]
        )
    }

    enum ReminderError: LocalizedError {
        case permissionDenied
        case dateInPast

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Notifications are disabled for Halls."
            case .dateInPast: "Choose a reminder time in the future."
            }
        }
    }
}
