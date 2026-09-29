import Foundation
import WidgetKit

/// Shared by the app, Shortcuts, and WidgetKit. No account or UI dependencies.
enum PSUDiningAccess {
    static let suiteName = "group.com.ryannair05.pennstatemeals"
    static var isEnabled: Bool { isEnabled(universityRawValue: UserDefaults(suiteName: suiteName)?.string(forKey: "selectedUniversity")) }
    static func isEnabled(universityRawValue: String?) -> Bool { universityRawValue == "psu" }
    static var root: URL {
        (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) ?? URL.cachesDirectory)
            .appending(path: "PSUDining-v1", directoryHint: .isDirectory)
    }
    static func requireEnabled() throws {
        guard isEnabled else { throw PSUDiningActionError.universityUnavailable }
    }
}

extension UserDefaults {
    // Construct on access; no shared mutable Foundation object crosses executors.
    static var shared: UserDefaults? { UserDefaults(suiteName: PSUDiningAccess.suiteName) }
}

enum PSUDiningActionError: Error, CustomLocalizedStringResourceConvertible {
    case universityUnavailable, invalidSelection, dateUnavailable, foodUnavailable, networkUnavailable, menuNotPublished, nutritionNotPublished, nutritionUnavailable
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .universityUnavailable: "Select Penn State in Halls to use PSU dining shortcuts and widgets."
        case .invalidSelection: "Choose a Penn State dining hall."
        case .dateUnavailable: "Choose a date within the available dining menu range."
        case .foodUnavailable: "This food is no longer available in that menu. Find the food again or open its dining hall menu."
        case .nutritionNotPublished: "Nutrition information is not published for this food."
        case .nutritionUnavailable: "Nutrition information could not be loaded. Try again when the dining service is available."
        case .menuNotPublished: "No menu has been published for this dining hall and date."
        case .networkUnavailable: "The dining service could not be reached and no saved menu is available. Try again when connected."
        }
    }
}

struct PSUFoodReference: Codable, Sendable, Hashable {
    let hall: String
    let date: DateOnly
    let mealID: String
    let sectionID: String
    let itemID: String

    var id: String {
        let fields = [hall, date.description, mealID, sectionID, itemID]
        // Encoding an array has a deterministic order, unlike JSON object keys.
        return "psu-food-v1:" + ((try? JSONEncoder().encode(fields)) ?? Data()).base64EncodedString()
    }
    init(hall: String, date: DateOnly, mealID: String, sectionID: String, itemID: String) {
        self.hall = hall; self.date = date; self.mealID = mealID; self.sectionID = sectionID; self.itemID = itemID
    }
    init?(id: String) {
        guard id.hasPrefix("psu-food-v1:"), id.utf8.count <= 4096,
              let data = Data(base64Encoded: String(id.dropFirst(12))),
              let fields = try? JSONDecoder().decode([String].self, from: data), fields.count == 5,
              PSUDiningHall(rawValue: fields[0]) != nil,
              let date = DateOnly(deepLinkValue: fields[1]),
              fields.dropFirst(2).allSatisfy({ !$0.isEmpty }) else { return nil }
        self.init(hall: fields[0], date: date, mealID: fields[2], sectionID: fields[3], itemID: fields[4])
    }
}

struct PSUFoodRecord: Codable, Sendable, Identifiable {
    let reference: PSUFoodReference
    let mealName: String
    let sectionName: String
    let item: DiningMenuItem
    var id: String { reference.id }
    var hallName: String { reference.hall.capitalized }
    static func records(in snapshot: MenuDaySnapshot) -> [Self] {
        snapshot.meals.flatMap { meal in
            meal.sections.flatMap { section in
                section.items.map { item in
                    Self(reference: PSUFoodReference(hall: snapshot.key.locationID.rawValue,
                        date: snapshot.key.localDate, mealID: meal.id, sectionID: section.id, itemID: item.id),
                         mealName: meal.displayName, sectionName: section.displayName, item: item)
                }
            }
        }
    }
}

/// One atomic file per hall/day avoids cross-process read-modify-write manifests.
actor PSUFoodCatalog {
    static let shared = PSUFoodCatalog()
    private struct Archive: Codable {
        let version: Int
        let fetchedAt: Date
        let records: [PSUFoodRecord]
    }
    let root: URL
    private var lastPrunedDate: DateOnly?
    init(root: URL = PSUDiningAccess.root.appending(path: "FoodReferences-v1")) { self.root = root }
    func replace(_ snapshot: MenuDaySnapshot) throws {
        let today = PSUServiceSelection.calendar.serviceDate(containing: .now)
        if lastPrunedDate != today {
            prune(before: today)
            lastPrunedDate = today
        }
        let destination = file(hall: snapshot.key.locationID.rawValue, date: snapshot.key.localDate)
        if let old = archive(at: destination), old.fetchedAt >= snapshot.fetchedAt { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(version: 1, fetchedAt: snapshot.fetchedAt, records: PSUFoodRecord.records(in: snapshot)))
            .write(to: destination, options: .atomic)
    }
    func records(hall: String, date: DateOnly) -> [PSUFoodRecord] {
        archive(at: file(hall: hall, date: date))?.records ?? []
    }
    func prune(before date: DateOnly) {
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.deletingPathExtension().lastPathComponent
            if let day = DateOnly(deepLinkValue: String(name.suffix(10))), day < date {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    private func archive(at url: URL) -> Archive? {
        guard let data = try? Data(contentsOf: url), let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1 else { return nil }
        return archive
    }
    private func file(hall: String, date: DateOnly) -> URL { root.appending(component: "\(hall)-\(date).json") }
}

enum PSUServiceSelection {
    static let calendar = ProviderCalendarContexts.pennState
    static func preferredLabel(at instant: Date, intervals: [DiningHoursInterval]) -> String? {
        let parts = calendar.calendar.dateComponents([.hour, .minute], from: instant)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let active = intervals.first { $0.startMinutesAfterMidnight <= minutes && minutes < $0.endMinutesAfterMidnight }
        let next = intervals.filter { minutes < $0.startMinutesAfterMidnight }.min { $0.startMinutesAfterMidnight < $1.startMinutesAfterMidnight }
        if let next, next.startMinutesAfterMidnight - minutes <= 15 { return next.label }
        return (active ?? next)?.label
    }
    static func meal(in snapshot: MenuDaySnapshot, preference: String, hours: DayHours?, now: Date) -> MenuMealPeriod? {
        if preference != "automatic" {
            return snapshot.meals.first { $0.servicePeriod.id.rawValue == preference }
        }
        if snapshot.key.localDate != calendar.serviceDate(containing: now) { return snapshot.meals.first }
        let availableIntervals = (hours?.intervals ?? []).filter { interval in
            guard let label = interval.label else { return false }
            return snapshot.meals.contains { DiningServicePeriodNormalizer.menuLabel($0.displayName, matchesHoursLabel: label) }
        }
        if let label = preferredLabel(at: now, intervals: availableIntervals),
           let meal = snapshot.meals.first(where: { DiningServicePeriodNormalizer.menuLabel($0.displayName, matchesHoursLabel: label) }) {
            return meal
        }
        // When hours are missing, use the same time-of-day fallback for every surface.
        let hour = calendar.calendar.component(.hour, from: now)
        let desired = if hour < 10 { "breakfast" } else if hour < 15 { "lunch" } else { "dinner" }
        return snapshot.meals.first { DiningServicePeriodNormalizer.menuLabel($0.displayName, matchesHoursLabel: desired) }
            ?? snapshot.meals.last
    }
    static func timelineTransitions(hours: DayHours?, now: Date) -> [Date] {
        let today = calendar.serviceDate(containing: now)
        let midnight = today.addingDays(1)?.date(in: calendar.timeZone, hour: 0)
        var boundaries = (hours?.intervals ?? []).flatMap { interval in
            [interval.startMinutesAfterMidnight - 15, interval.startMinutesAfterMidnight, interval.endMinutesAfterMidnight]
        }.compactMap { calendar.date(on: today, minutesAfterMidnight: $0) }.filter { $0 > now }
        // Match the automatic meal fallback even when a hall has no published hours.
        boundaries += [10 * 60, 15 * 60].compactMap {
            calendar.date(on: today, minutesAfterMidnight: $0)
        }.filter { $0 > now }
        if let midnight { boundaries.append(midnight) }
        return Array(Set(boundaries)).sorted()
    }
    static func nextRefresh(hours: DayHours?, now: Date) -> Date {
        min(timelineTransitions(hours: hours, now: now).first ?? now.addingTimeInterval(3600), now.addingTimeInterval(2 * 3600))
    }
    /// Match relevance to the displayed meal and published hours, not guessed daily times.
    /// The existing timeline already includes the 15-minute lead-in and closing boundaries.
    static func relevanceEnd(meal: MenuMealPeriod?, hours: DayHours?, date: DateOnly, at instant: Date) -> Date? {
        guard let meal, let hours, !hours.isExplicitlyClosed,
              date == calendar.serviceDate(containing: instant) else { return nil }
        return hours.intervals.compactMap { interval -> Date? in
            guard let label = interval.label,
                  DiningServicePeriodNormalizer.menuLabel(meal.displayName, matchesHoursLabel: label),
                  let start = calendar.date(on: date, minutesAfterMidnight: max(0, interval.startMinutesAfterMidnight - 15)),
                  let end = calendar.date(on: date, minutesAfterMidnight: interval.endMinutesAfterMidnight),
                  start <= instant, instant < end else { return nil }
            return end
        }.max()
    }
    static func status(hours: DayHours?, date: DateOnly, now: Date) -> String? {
        guard let hours, hours.isExplicitlyClosed || !hours.intervals.isEmpty else { return nil }
        if hours.isExplicitlyClosed { return "Closed" }
        guard date == calendar.serviceDate(containing: now) else { return nil }
        let parts = calendar.calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return hours.intervals.contains { $0.startMinutesAfterMidnight <= minutes && minutes < $0.endMinutesAfterMidnight } ? "Open now" : "Closed now"
    }
}

struct PSUActionMenu: Sendable {
    let snapshot: MenuDaySnapshot
    let meal: MenuMealPeriod?
    let hours: DayHours?
    let isStale: Bool
}

/// Selection for intent answers only. Full menus and food lookup retain timed stations.
enum PSUDiningMenuSelection {
    private static let servingTime = try! NSRegularExpression(
        pattern: #"(?ix)\b(?:[01]?\d|2[0-3]):[0-5]\d\b|\b(?:1[0-2]|0?[1-9])(?::[0-5]\d)?\s*[ap]\.?\s*m\.?\b|\b(?:[01]?\d|2[0-3])\s*(?:[-–—]|to)\s*(?:[01]?\d|2[0-3])\b|\b(?:noon|midnight)\b"#)

    static func hasServingTime(_ heading: String) -> Bool {
        servingTime.firstMatch(in: heading, range: NSRange(heading.startIndex..., in: heading)) != nil
    }

    static func records(in result: PSUActionMenu) -> [PSUFoodRecord] {
        guard let meal = result.meal else { return [] }
        return meal.sections.filter { !hasServingTime($0.displayName) }.flatMap { section in
            section.items.map { item in
                PSUFoodRecord(reference: .init(hall: result.snapshot.key.locationID.rawValue,
                    date: result.snapshot.key.localDate, mealID: meal.id,
                    sectionID: section.id, itemID: item.id),
                    mealName: meal.displayName, sectionName: section.displayName, item: item)
            }
        }
    }

    static func previewNames(in records: [PSUFoodRecord]) -> [String] {
        guard let first = records.first else { return [] }
        var seen: Set<String> = []
        var names: [String] = []
        for record in records.prefix(while: { $0.reference.sectionID == first.reference.sectionID }) {
            let name = record.item.displayName
            let key = DiningTextNormalizer.foldedWords(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            names.append(name)
            if names.count == 5 { break }
        }
        return names
    }
}

final class PSUDiningServices: Sendable {
    static let shared = PSUDiningServices()
    /// Intent access is independent of onboarding; all costly services are shared.
    static let intents = PSUDiningServices(sharing: shared)
    private init(sharing base: PSUDiningServices) {
        fileStore = base.fileStore
        repository = base.repository
        hours = base.hours
        catalog = base.catalog
        now = base.now
        isEnabled = { true }
        didLoad = base.didLoad
        detailProvider = base.detailProvider
    }
    let fileStore: MenuSnapshotFileStore
    let repository: DefaultDiningMenuRepository
    let hours: PSUDiningHours
    private let catalog: PSUFoodCatalog
    private let now: @Sendable () -> Date
    private let isEnabled: @Sendable () -> Bool
    private let didLoad: @Sendable @concurrent (MenuDaySnapshot) async -> Void
    private let detailProvider: MenuItemDetailRepositoryProvider

    init(root: URL = PSUDiningAccess.root) {
        let hours = PSUDiningHours(rootDirectory: root.appending(path: "Hours"))
        let store = MenuSnapshotFileStore(rootDirectory: root.appending(path: "Menus-v3"), sharedAcrossProcesses: true)
        let sourceAdapter = PSUMenuSourceAdapterImpl(httpClient: .shared)
        self.hours = hours
        fileStore = store
        catalog = .shared
        now = { .now }
        isEnabled = { PSUDiningAccess.isEnabled }
        didLoad = { @concurrent snapshot in await PSUDiningWidgetUpdates.shared.menuDidLoad(snapshot) }
        detailProvider = MenuItemDetailRepositoryProvider(rootDirectory: root.appending(path: "MenuItemDetails"))
        repository = DefaultDiningMenuRepository(fileStore: store, readsSharedStore: true, loadSnapshot: { @concurrent key, preference, progress in
            guard let hall = PSUDiningHall(rawValue: key.locationID.rawValue), key.locationID.provider == .pennState else {
                throw PSUDiningActionError.invalidSelection
            }
            return try await sourceAdapter.load(PSUMenuSourceRequest(location: hall, localDate: key.localDate),
                                                preferredPeriod: preference, onPartialSnapshot: progress)
        }, isStale: { @concurrent snapshot, now in
            let dayHours = await hours.hours(for: snapshot.key.locationID, on: snapshot.key.localDate)
            return PSUMenuFreshnessPolicy.isStale(snapshot, at: now, dayHours: dayHours)
        })
    }
    init(repository: DefaultDiningMenuRepository, fileStore: MenuSnapshotFileStore, hours: PSUDiningHours,
         catalog: PSUFoodCatalog, now: @escaping @Sendable () -> Date,
         isEnabled: @escaping @Sendable () -> Bool,
         didLoad: @escaping @Sendable @concurrent (MenuDaySnapshot) async -> Void = { @concurrent _ in }) {
        self.repository = repository
        self.fileStore = fileStore
        self.hours = hours
        self.catalog = catalog
        self.now = now
        self.isEnabled = isEnabled
        self.didLoad = didLoad
        detailProvider = MenuItemDetailRepositoryProvider(rootDirectory: nil)
    }
    private func requireEnabled() throws {
        guard isEnabled() else { throw PSUDiningActionError.universityUnavailable }
    }
    /// Hours come from the existing aggregate cache, not from five menu downloads.
    @concurrent func diningHours(hall: PSUDiningHall, date: DateOnly) async throws -> DayHours? {
        try Task.checkCancellation()
        try requireEnabled()
        guard hall.calendarContext.contains(date, relativeTo: now()) else { throw PSUDiningActionError.dateUnavailable }
        let result = await hours.hours(for: hall.locationID, on: date)
        try Task.checkCancellation()
        return result
    }
    @concurrent func menu(hall: PSUDiningHall, date: DateOnly, preference: String = "automatic") async throws -> PSUActionMenu {
        try Task.checkCancellation()
        try requireEnabled()
        guard hall.calendarContext.contains(date, relativeTo: now()) else { throw PSUDiningActionError.dateUnavailable }
        let snapshot: MenuDaySnapshot
        do { snapshot = try await repository.menu(for: MenuDayKey(locationID: hall.locationID, localDate: date), policy: .revalidateIfStale) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            if let source = error as? PSUMenuSourceAdapterError, source.sourceError == .noPublishedMenu {
                throw PSUDiningActionError.menuNotPublished
            }
            throw PSUDiningActionError.networkUnavailable
        }
        try Task.checkCancellation()
        try requireEnabled()
        try? await catalog.replace(snapshot)
        let publish = didLoad
        Task { @concurrent in await publish(snapshot) }
        let dayHours = await hours.hours(for: hall.locationID, on: date)
        try Task.checkCancellation()
        try requireEnabled()
        return PSUActionMenu(snapshot: snapshot,
            meal: PSUServiceSelection.meal(in: snapshot, preference: preference, hours: dayHours, now: now()),
            hours: dayHours, isStale: PSUMenuFreshnessPolicy.isStale(snapshot, at: now(), dayHours: dayHours))
    }
    @concurrent func resolve(_ reference: PSUFoodReference) async throws -> PSUFoodRecord {
        guard let hall = PSUDiningHall(rawValue: reference.hall) else { throw PSUDiningActionError.invalidSelection }
        let loaded = try await menu(hall: hall, date: reference.date)
        guard let record = PSUFoodRecord.records(in: loaded.snapshot).first(where: { $0.id == reference.id }) else {
            throw PSUDiningActionError.foodUnavailable
        }
        return record
    }
    @concurrent func search(text: String, date: DateOnly, hall: PSUDiningHall?, meal: String?) async throws -> (records: [PSUFoodRecord], failedHalls: [String]) {
        try Task.checkCancellation()
        try requireEnabled()
        let halls = hall.map { [$0] } ?? PSUDiningHall.allCases
        let words = DiningTextNormalizer.foldedWords(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ([], []) }
        // There are at most five hall tasks. Every HTTP request still passes through
        // PSUHTTPRequestBudget (three requests), shared with foreground menu loads.
        let outcomes = try await withThrowingTaskGroup(of: PSUSearchHallOutcome.self) { @concurrent group in
            for hall in halls {
                group.addTask { @concurrent [self] in
                    try Task.checkCancellation()
                    do {
                        let result = try await menu(hall: hall, date: date)
                        let records = PSUFoodRecord.records(in: result.snapshot).filter { record in
                            let name = DiningTextNormalizer.foldedWords(record.item.displayName)
                            return words.allSatisfy { name.contains($0) }
                                && (meal == nil || meal == "automatic"
                                    || DiningServicePeriodNormalizer.normalize(record.mealName).id.rawValue == meal)
                        }
                        return PSUSearchHallOutcome(hall: hall, records: records, failed: result.isStale)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        try requireEnabled()
                        if let error = error as? PSUDiningActionError {
                            switch error {
                            case .dateUnavailable: throw error
                            case .menuNotPublished: return PSUSearchHallOutcome(hall: hall, records: [], failed: false)
                            default: break
                            }
                        }
                        return PSUSearchHallOutcome(hall: hall, records: [], failed: true)
                    }
                }
            }
            var outcomes: [PSUDiningHall: PSUSearchHallOutcome] = [:]
            for try await outcome in group { outcomes[outcome.hall] = outcome }
            return outcomes
        }
        try Task.checkCancellation()
        try requireEnabled()
        let matches = halls.flatMap { outcomes[$0]?.records ?? [] }
        let failures = halls.filter { outcomes[$0]?.failed == true }.map { $0.rawValue.capitalized }
        if matches.isEmpty && failures.count == halls.count { throw PSUDiningActionError.networkUnavailable }
        return (matches, failures)
    }

    @concurrent func nutrition(for record: PSUFoodRecord) async throws -> PSUMenuItemDetailState {
        try Task.checkCancellation()
        try requireEnabled()
        if let metadata = record.item.detailMetadata,
           (0..<PSUMenuItemDetailRepository.cacheInterval).contains(now().timeIntervalSince(metadata.fetchedAt)) {
            return .available(PSUMenuItemDetail(itemID: record.item.id, metadata: metadata))
        }
        guard let url = record.item.detailURL else { throw PSUDiningActionError.nutritionNotPublished }
        do {
            let repository = try await detailProvider.repository()
            let detail = try await repository.detail(for: record.item.id, displayName: record.item.displayName, sourceURL: url)
            try Task.checkCancellation()
            try requireEnabled()
            return detail
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            try requireEnabled()
            throw PSUDiningActionError.nutritionUnavailable
        }
    }
}

private struct PSUSearchHallOutcome: Sendable {
    let hall: PSUDiningHall
    let records: [PSUFoodRecord]
    let failed: Bool
}


/// Menu loads can refresh widgets without involving the Spotlight index.
actor PSUDiningWidgetUpdates {
    static let shared = PSUDiningWidgetUpdates()
    private var snapshots: [String: Date] = [:]

    func menuDidLoad(_ snapshot: MenuDaySnapshot) {
        guard !Bundle.main.bundlePath.hasSuffix(".appex"), PSUDiningAccess.isEnabled,
              snapshot.key.locationID.provider == .pennState,
              PSUDiningHall(rawValue: snapshot.key.locationID.rawValue) != nil,
              snapshot.key.localDate == PSUServiceSelection.calendar.serviceDate(containing: .now) else { return }
        let hall = snapshot.key.locationID.rawValue
        guard snapshots[hall].map({ $0 < snapshot.fetchedAt }) ?? true else { return }
        snapshots[hall] = snapshot.fetchedAt
        WidgetCenter.shared.reloadTimelines(ofKind: "PSUDiningMenuWidget-v1")
    }
}
