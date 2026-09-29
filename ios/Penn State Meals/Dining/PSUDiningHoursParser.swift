import Foundation

enum PSUDiningHoursLocation: String, CaseIterable, Codable, Sendable {
    case north, east, pollock, south, west

    var locationID: DiningLocationID { DiningLocationID(provider: .pennState, rawValue: rawValue) }

    var sourceTitle: String {
        switch self {
        case .north: "Northside @ Warnock Commons"
        case .east: "East Food District Buffet"
        case .pollock: "Pollock Commons Buffet"
        case .south: "Southside Buffet @ South Food District"
        case .west: "Waring Square Buffet @ West"
        }
    }
}

enum PSUDiningHoursError: Error, Sendable, Equatable {
    case invalidResponse
    case noSupportedLocations
}

/// The complete Penn State dining-hours source: aggregate transport, parsing, freshness,
/// request coalescing, and its single unversioned disk cache.
actor PSUDiningHours {
    private static let currentCacheSchemaVersion = 2
    typealias Fetch = @concurrent @Sendable (URLRequest) async throws(DiningSourceError) -> Data

    static let aggregateURL = URL(
        string: "https://liveon.prod.fbweb.psu.edu/json/up/hours"
    ).unsafelyUnwrapped
    static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let retryDelay: TimeInterval = 15 * 60

    private struct Cache: Codable, Sendable, Equatable {
        let schemaVersion: Int
        let fetchedAt: Date
        let locations: [String: WeeklyHours]

        init(fetchedAt: Date, locations: [String: WeeklyHours]) {
            self.schemaVersion = PSUDiningHours.currentCacheSchemaVersion
            self.fetchedAt = fetchedAt
            self.locations = locations
        }
    }

    private struct RawRecord: Decodable {
        struct RawHour: Decodable {
            let day: String?
            let start: String?
            let end: String?
            let timezone: String?
            let comment: String?
        }
        let diningLocation: String?
        let diningArea: String?
        let hours: [RawHour]?
        enum CodingKeys: String, CodingKey {
            case diningLocation = "dining_location"
            case diningArea = "dining_area"
            case hours
        }
    }

    private let fileURL: URL
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var cache: Cache?
    private var loadedDisk = false
    private var retryAfter: Date?
    private var refreshTask: Task<Cache, any Error>?

    init(
        rootDirectory: URL? = nil,
        fetch: @escaping Fetch = {
            @concurrent (request: URLRequest) async throws(DiningSourceError) -> Data in
            try await PSUHTTPRequestBudget.shared.withPermit {
                @concurrent () async throws(DiningSourceError) -> Data in
                try await DiningHTTPClient.shared.data(for: request).data
            }
        },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        let root = rootDirectory ?? URL.cachesDirectory
            .appending(components: "MeetAndEat", "DiningHours", directoryHint: .isDirectory)
        self.fileURL = root.appending(component: "penn-state.json", directoryHint: .notDirectory)
        self.fetch = fetch
        self.now = now
    }

    func hours(
        for locationID: DiningLocationID,
        on date: DateOnly,
        policy: DiningHoursLoadPolicy = .revalidateIfNeeded
    ) async -> DayHours? {
        guard locationID.provider == .pennState,
              let weekday = date.weekday() else { return nil }
        await loadDiskIfNeeded()
        let instant = now()
        if policy != .forceRevalidation, let cache, isFresh(cache, at: instant) {
            return cache.locations[locationID.rawValue]?[weekday]
        }
        guard policy != .cacheOnly else { return nil }
        guard retryAfter.map({ instant >= $0 }) ?? true else { return nil }
        do {
            let refreshed = try await refresh(at: instant)
            return refreshed.locations[locationID.rawValue]?[weekday]
        } catch {
            retryAfter = instant.addingTimeInterval(Self.retryDelay)
            return nil
        }
    }

    /// Explicit menu-section aliases, scoped by hall. Related food categories can
    /// belong to one venue; matching never crosses halls or guesses from food names.
    nonisolated static func stationKey(for section: String, hall: PSUDiningHall) -> String {
        let name = DiningTextNormalizer.foldedWords(section)
        let aliases: [String: String] = switch hall {
        case .north: ["greens grains": "Greens + Grains @ Market North",
                      "halal cart bowls": "Halal Cart @ Market North",
                      "halal cart chips dips": "Halal Cart @ Market North",
                      "halal cart flats wraps": "Halal Cart @ Market North",
                      "halal cart special features": "Halal Cart @ Market North",
                      "halal cart sweets": "Halal Cart @ Market North"]
        case .east: ["aloha fresh": "Aloha Fresh Poke Bowls", "bowls": "Bowls @ East",
                     "east philly": "East Philly Cheesesteaks", "edge": "Edge @ East",
                     "fresco": "Fresco @ East", "pizza": "Pizza @ East"]
        case .south: ["amici": "Amici Italian Market", "bowls": "Bowls @ South",
                      "choolaah": "Choolaah Indian BBQ", "choolah": "Choolaah Indian BBQ",
                      "edge": "Edge @ South", "on a roll": "On a Roll @ South"]
        case .west: ["edge": "Edge @ West", "state chik n": "State Chik'n in Waring"]
        case .pollock: ["edge": "Edge @ Pollock", "edge online menu": "Edge @ Pollock",
                        "fresco": "Fresco @ Pollock", "mpk asia": "Market Pollock Asia Kitchen"]
        }
        return aliases[name].map { DiningTextNormalizer.foldedWords($0) } ?? name
    }

    /// The hall load has already populated the same aggregate cache; never starts a request.
    func stationHours(for hall: PSUDiningHall, on date: DateOnly) -> [String: DayHours] {
        guard let cache, isFresh(cache, at: now()), let weekday = date.weekday() else { return [:] }
        let prefix = "station:\(hall.rawValue):"
        return Dictionary(uniqueKeysWithValues: cache.locations.compactMap { key, weekly in
            guard key.hasPrefix(prefix) else { return nil }
            return (String(key.dropFirst(prefix.count)), weekly[weekday])
        })
    }

    private func loadDiskIfNeeded() async {
        guard !loadedDisk else { return }
        loadedDisk = true
        do {
            let loaded = try Self.decodeCache(Data(contentsOf: fileURL, options: .mappedIfSafe))
            cache = isFresh(loaded, at: now()) ? loaded : nil
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func refresh(at instant: Date) async throws -> Cache {
        if let refreshTask { return try await refreshTask.value }
        let fetch = self.fetch
        let task = Task { @concurrent in
            var request = URLRequest(url: Self.aggregateURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            let locations = try Self.parseAggregateJSON(await fetch(request))
            return Cache(fetchedAt: instant, locations: locations)
        }
        refreshTask = task
        defer { refreshTask = nil }
        let result = try await task.value
        cache = result
        retryAfter = nil
        try? Self.store(result, at: fileURL)
        return result
    }

    private func isFresh(_ cache: Cache, at instant: Date) -> Bool {
        let age = instant.timeIntervalSince(cache.fetchedAt)
        return age >= 0 && age < Self.cacheLifetime
    }

    nonisolated static func parseAggregateJSON(
        _ data: Data
    ) throws(PSUDiningHoursError) -> [String: WeeklyHours] {
        guard let records = try? JSONDecoder().decode([RawRecord].self, from: data) else {
            throw PSUDiningHoursError.invalidResponse
        }
        var result: [String: WeeklyHours] = [:]
        let areas = ["South Food District": "south", "East Food District": "east",
                     "West Food District": "west", "North Food District": "north",
                     "Pollock Dining Commons": "pollock"]
        var groups = Dictionary(uniqueKeysWithValues: PSUDiningHoursLocation.allCases.map { location in
            (location.rawValue, records.filter { $0.diningLocation == location.sourceTitle })
        })
        for record in records {
            guard let area = record.diningArea, let hall = areas[area],
                  let name = record.diningLocation else { continue }
            let decodedName = name.replacingOccurrences(of: "&#039;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
            let key = "station:\(hall):" + DiningTextNormalizer.foldedWords(decodedName)
            groups[key, default: []].append(record)
        }
        for (key, matching) in groups {
            guard !matching.isEmpty else { continue }
            var weekly = WeeklyHours.unknown
            for weekday in DiningWeekday.allCases {
                let sourceHours = matching.flatMap { $0.hours ?? [] }.filter {
                    $0.day.flatMap(DiningWeekday.init(sourceName:)) == weekday
                }
                guard !sourceHours.isEmpty else { continue }
                var intervals: [DiningHoursInterval] = []
                var explicitlyClosed = false
                for hour in sourceHours {
                    guard hour.timezone == nil
                            || hour.timezone == ProviderCalendarContexts.pennState.timeZone.identifier else {
                        continue
                    }
                    let label = nonempty(hour.comment)
                    if hour.start == nil, hour.end == nil {
                        explicitlyClosed = explicitlyClosed || label?.localizedCaseInsensitiveContains("closed") == true
                        continue
                    }
                    guard let startText = hour.start, let endText = hour.end,
                          let start = minutes(startText), var end = minutes(endText) else { continue }
                    if end == 0 && start > 0 { end = 1_440 }
                    if let interval = try? DiningHoursInterval(
                        startMinutesAfterMidnight: start,
                        endMinutesAfterMidnight: end,
                        label: label
                    ) { intervals.append(interval) }
                }
                intervals.sort { $0.startMinutesAfterMidnight < $1.startMinutesAfterMidnight }
                weekly = weekly.replacing(weekday, with: DayHours(
                    intervals: intervals,
                    isExplicitlyClosed: intervals.isEmpty && explicitlyClosed
                ))
            }
            result[key] = weekly
        }
        guard !result.isEmpty else { throw PSUDiningHoursError.noSupportedLocations }
        return result
    }

    private nonisolated static func minutes(_ value: String) -> Int? {
        let components = value.prefix(5).split(separator: ":")
        guard components.count == 2, let hour = Int(components[0]), let minute = Int(components[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private nonisolated static func nonempty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private nonisolated static func decodeCache(_ data: Data) throws -> Cache {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cache = try decoder.decode(Cache.self, from: data)
        guard cache.schemaVersion == currentCacheSchemaVersion else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Unsupported dining-hours cache schema: \(cache.schemaVersion)"
            ))
        }
        return cache
    }

    private nonisolated static func store(_ cache: Cache, at fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(cache).write(to: fileURL, options: .atomic)
    }
}
