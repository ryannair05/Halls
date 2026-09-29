import Foundation

struct DiningProviderID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension DiningProviderID {
    static let pennState = DiningProviderID(rawValue: "psu")
    /// Retains the legacy raw value so existing Barnard cache and deep-link identities remain valid.
    static let barnard = DiningProviderID(rawValue: "barnard-columbia")
    static let columbia = DiningProviderID(rawValue: "columbia")
    static let uga = DiningProviderID(rawValue: "uga")
}

struct DiningLocationID: Hashable, Codable, Sendable {
    let provider: DiningProviderID
    let rawValue: String
}

struct MenuDayKey: Hashable, Codable, Sendable {
    static let officialSourceVariant = "official"

    let locationID: DiningLocationID
    let localDate: DateOnly
    let sourceVariant: String

    init(
        locationID: DiningLocationID,
        localDate: DateOnly,
        sourceVariant: String = MenuDayKey.officialSourceVariant
    ) {
        self.locationID = locationID
        self.localDate = localDate
        self.sourceVariant = sourceVariant
    }

}

/// A calendar day with no implicit time zone or midnight `Date` representation.
struct DateOnly: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    private init(uncheckedYear year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(year: Int, month: Int, day: Int) {
        guard Self.isValid(year: year, month: month, day: day) else { return nil }
        self.init(uncheckedYear: year, month: month, day: day)
    }

    init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        precondition(
            Self.isValid(year: year, month: month, day: day),
            "Date cannot be represented as a supported civil date"
        )
        self.init(
            uncheckedYear: year,
            month: month,
            day: day
        )
    }

    func date(in timeZone: TimeZone, hour: Int = 12) -> Date? {
        guard (0...23).contains(hour) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        )
        guard let represented = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour], from: represented)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day,
              roundTrip.hour == hour else { return nil }
        return represented
    }

    var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: DateOnly, rhs: DateOnly) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    private static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (1...9_999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(
            calendar: calendar,
            timeZone: .gmt,
            year: year,
            month: month,
            day: day,
            hour: 12
        )
        guard let represented = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: represented)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }

    private enum CodingKeys: String, CodingKey {
        case year, month, day
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let year = try container.decode(Int.self, forKey: .year)
        let month = try container.decode(Int.self, forKey: .month)
        let day = try container.decode(Int.self, forKey: .day)
        guard let value = DateOnly(year: year, month: month, day: day) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid civil date: \(year)-\(month)-\(day)"
            ))
        }
        self = value
    }

}
