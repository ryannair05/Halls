import Foundation

enum CampusDiningSchool: String, Sendable {
    case barnardColumbia, uga

    var title: String { self == .uga ? "UGA Dining" : "Barnard & Columbia" }
}

struct CampusDiningLocation: Codable, Hashable, Sendable, Identifiable {
    let id: DiningLocationID
    let name: String
    let sourceID: String
    let sourceURL: URL
    let group: String
    let isRetail: Bool
    var mealTypes: [String] = []
    var information: String?

    var displayName: String {
        switch (id.provider, id.rawValue) {
        case (.barnard, "hewitt"): "Hewitt"
        case (.barnard, "kosher"): "Barnard Kosher"
        case (.barnard, "diana"): "Diana Center Café"
        case (.barnard, "liz"): "Liz’s Place"
        case (.barnard, "lefrak"): "LeFrak Center"
        case (.barnard, "milstein"): "Bubble Tea & Sushi"
        case (.uga, "bolton"): "Bolton"
        case (.uga, "hillside"): "Hillside"
        case (.uga, "oglethorpe"): "Oglethorpe"
        case (.uga, "snelling"): "Snelling"
        case (.uga, "niche"): "The Niche"
        case (.uga, "village"): "Village Summit"
        default: name
        }
    }

    var calendarContext: ProviderCalendarContext {
        switch id.provider {
        case .uga: ProviderCalendarContexts.uga
        case .columbia: ProviderCalendarContexts.columbia
        default: ProviderCalendarContexts.barnardColumbia
        }
    }

    // A bundled catalog keeps navigation available offline, before discovery completes.
    static func initialLocations(for school: CampusDiningSchool) -> [Self] {
        if school == .uga {
            return [
                ("bolton", "Bolton", "dining-hall-1"),
                ("hillside", "Hillside", "hillside-dining-commons"),
                ("oglethorpe", "Oglethorpe", "dining-hall-2"),
                ("snelling", "Snelling", "dining-hall-3"),
                ("niche", "The Niche", "dining-hall-4"),
                ("village", "Village Summit", "dining-hall-5")
            ].map { raw, name, slug in
                Self(id: .init(provider: .uga, rawValue: raw), name: name, sourceID: slug,
                     sourceURL: URL(string: "https://uga.nutrislice.com/menu/\(slug)")!,
                     group: "Dining Commons", isRetail: false)
            }
        }
        let barnard: [Self] = [
            ("hewitt", "Hewitt Dining", "5d27a0461ca48e0aca2a104c", "hewitt-dining", false),
            ("kosher", "Barnard Kosher", "5d794b63c4b7ff15288ba3da", "barnard-kosher-hewitt-food-hall", false),
            ("diana", "Diana Center Café", "5d8775484198d40d7a0b8078", "diana-center-cafe", false),
            ("liz", "Liz’s Place", "5d79274b1ca48e10b33c4884", "liz-s-place", true),
            ("lefrak", "LeFrak Center", "67252a74351d530746aa3f21", "lefrak-center", true),
            ("milstein", "Bubble Tea & Sushi", "63e6c3b1351d53062192e8a4", "barnard-dining-bubble-tea-and-sushi-spot", true)
        ].map { raw, name, id, slug, retail in
            Self(id: .init(provider: .barnard, rawValue: raw), name: name, sourceID: id,
                 sourceURL: URL(string: "https://dineoncampus.com/barnard/whats-on-the-menu/\(slug)")!,
                 group: "Barnard", isRetail: retail)
        }
        let columbia: [Self] = [
            ("10", "John Jay", "/content/john-jay-dining-hall"),
            ("11", "JJ’s Place", "/content/jjs-place-0"),
            ("12", "Ferris Booth", "/content/ferris-booth-commons-0"),
            ("6907", "Chef Mike’s Sub Shop", "/chef-mikes"),
            ("6990", "Chef Don’s Pizza Pi", "/content/chef-dons-pizza-pi-ft-blue-java"),
            ("7351", "Faculty House · 2nd Floor", "/content/faculty-house-2nd-floor-0"),
            ("7850", "Faculty House · 4th Floor", "/content/faculty-house-4th-floor-skyline-room"),
            ("7355", "Grace Dodge", "/content/grace-dodge-dining-hall-0"),
            ("9727", "Johnny’s Food Truck", "/johnnys"),
            ("7487", "Fac Shack", "/content/fac-shack-0"),
            ("7482", "Blue Java · Everett", "/content/blue-java-everett-library-cafe"),
            ("56", "Blue Java · Butler", "/content/blue-java-cafe-butler-library-0"),
            ("60", "Blue Java · Uris", "/content/blue-java-cafe-uris-hall"),
            ("57", "Blue Java · Mudd", "/content/blue-java-cafe-mudd-hall-0"),
            ("58", "Lenfest Café", "/content/lenfest-cafe-0"),
            ("7452", "Robert F. Smith Dining Hall", "/content/robert-f-smith-dining-hall-0")
        ].map { id, name, path in
            Self(id: .init(provider: .columbia, rawValue: id), name: name, sourceID: id,
                 sourceURL: URL(string: "https://dining.columbia.edu\(path)")!,
                 group: "Columbia", isRetail: ["7482", "56", "60", "57", "58", "7452"].contains(id))
        }
        return barnard + columbia
    }
}

struct CampusDiningHours: Codable, Sendable {
    struct Interval: Codable, Hashable, Sendable {
        let start: Date
        let end: Date
    }
    let intervals: [Interval]
    let isClosed: Bool
    let sourceText: String?
    let fetchedAt: Date
    var carryoverIntervals: [Interval] = []

    var summary: String {
        if isClosed { return "Closed" }
        if !intervals.isEmpty {
            let style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: ProviderCalendarContexts.uga.timeZone)
            // Providers can repeat a time window across schedule entries. Keep
            // genuinely different windows, but display each interval only once.
            let uniqueIntervals = Set(intervals).sorted {
                $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
            }
            return uniqueIntervals.map {
                return "\($0.start.formatted(style))–\($0.end.formatted(style))"
            }.joined(separator: " · ")
        }
        return sourceText ?? "Hours unavailable"
    }

    var currentStatus: String? {
        guard Date.now.timeIntervalSince(fetchedAt) < 3_600 else { return nil }
        if carryoverIntervals.contains(where: { $0.start <= .now && .now < $0.end }) { return "Open now" }
        if isClosed { return "Closed" }
        if intervals.contains(where: { $0.start <= .now && .now < $0.end }) { return "Open now" }
        if !intervals.isEmpty { return "Closed now" }
        return nil
    }
}

enum CampusMenuAvailability: String, Codable, Sendable {
    case published, unpublished, closed, partial
}

struct CampusMenuResult: Codable, Sendable {
    let snapshot: MenuDaySnapshot
    let availability: CampusMenuAvailability
    var isStale: Bool = false
    var message: String?
    var descriptions: [String: String] = [:]
}

enum CampusDiningError: Error, LocalizedError, Sendable {
    case invalidResponse, schema(String), http(Int), noMenu

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The dining provider returned an invalid response."
        case .schema: "The dining provider changed its menu format. Please try again later."
        case .http: "The dining provider is temporarily unavailable."
        case .noMenu: "No menu has been published for this date."
        }
    }
}

/// Provider JSON stays Sendable, including feeds with number-or-string identifiers and nutrients.
/// Missing required containers are checked by each adapter, not silently decoded as empty menus.
enum CampusJSON: Codable, Sendable {
    case object([String: CampusJSON]), array([CampusJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([CampusJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: CampusJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> Self { object[key] ?? .null }
    var object: [String: Self] { if case .object(let v) = self { v } else { [:] } }
    var array: [Self] { if case .array(let v) = self { v } else { [] } }
    var isArray: Bool { if case .array = self { true } else { false } }
    var isObject: Bool { if case .object = self { true } else { false } }
    var string: String {
        switch self {
        case .string(let v): v
        case .number(let v): v.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...6)))
        default: ""
        }
    }
    var int: Int { Int(string) ?? 0 }
    var bool: Bool { if case .bool(let v) = self { v } else { int == 1 } }
    var nonempty: String? { string.isEmpty ? nil : string }
}

enum CampusDiningSource {
    static func snapshot(location: CampusDiningLocation, date: DateOnly, meals: [MenuMealPeriod], fetchedAt: Date) -> MenuDaySnapshot {
        let key = MenuDayKey(locationID: location.id, localDate: date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(meals)) ?? Data()
        return MenuDaySnapshot(schemaVersion: MenuDaySnapshot.currentSchemaVersion, key: key,
                               fetchedAt: fetchedAt, sourceContentHash: DiningContentHasher.hash(data), meals: meals)
    }

    static func ordered(_ values: [CampusJSON], key: String) -> [CampusJSON] {
        values.enumerated().sorted {
            let a = $0.element[key].nonempty.flatMap(Int.init) ?? $0.offset
            let b = $1.element[key].nonempty.flatMap(Int.init) ?? $1.offset
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }

    static func date(_ date: DateOnly, minutes: Int) -> Date? {
        let context = ProviderCalendarContexts.uga
        guard let midnight = context.date(on: date, minutesAfterMidnight: 0) else { return nil }
        return context.calendar.date(byAdding: .minute, value: minutes, to: midnight)
    }
}
