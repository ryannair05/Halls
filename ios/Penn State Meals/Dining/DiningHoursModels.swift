import Foundation

enum DiningWeekday: Int, CaseIterable, Codable, Sendable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    init?(sourceName: String) {
        switch sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sunday": self = .sunday
        case "monday": self = .monday
        case "tuesday": self = .tuesday
        case "wednesday": self = .wednesday
        case "thursday": self = .thursday
        case "friday": self = .friday
        case "saturday": self = .saturday
        default: return nil
        }
    }
}

struct WeeklyHours: Codable, Sendable, Equatable {
    private let days: [DayHours]

    private init(days: [DayHours]) { self.days = days }

    static var unknown: WeeklyHours {
        WeeklyHours(days: Array(
            repeating: DayHours(intervals: [], isExplicitlyClosed: false),
            count: DiningWeekday.allCases.count
        ))
    }

    subscript(_ weekday: DiningWeekday) -> DayHours { days[weekday.rawValue - 1] }

    func replacing(_ weekday: DiningWeekday, with hours: DayHours) -> WeeklyHours {
        var result = days
        result[weekday.rawValue - 1] = hours
        return WeeklyHours(days: result)
    }

    private enum CodingKeys: String, CodingKey {
        case days
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let days = try container.decode([DayHours].self, forKey: .days)
        guard days.count == DiningWeekday.allCases.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .days,
                in: container,
                debugDescription: "Weekly hours must contain exactly seven days"
            )
        }
        self.init(days: days)
    }

}

struct DayHours: Codable, Sendable, Equatable {
    let intervals: [DiningHoursInterval]
    let isExplicitlyClosed: Bool
}

struct DiningHoursInterval: Codable, Sendable, Equatable {
    let startMinutesAfterMidnight: Int
    let endMinutesAfterMidnight: Int
    let label: String?

    init(
        startMinutesAfterMidnight: Int,
        endMinutesAfterMidnight: Int,
        label: String?
    ) throws(DiningHoursModelError) {
        guard (0..<1_440).contains(startMinutesAfterMidnight),
              (1...1_440).contains(endMinutesAfterMidnight),
              endMinutesAfterMidnight > startMinutesAfterMidnight else {
            throw DiningHoursModelError.invalidInterval(
                start: startMinutesAfterMidnight,
                end: endMinutesAfterMidnight
            )
        }
        self.startMinutesAfterMidnight = startMinutesAfterMidnight
        self.endMinutesAfterMidnight = endMinutesAfterMidnight
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case startMinutesAfterMidnight, endMinutesAfterMidnight, label
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Int.self, forKey: .startMinutesAfterMidnight)
        let end = try container.decode(Int.self, forKey: .endMinutesAfterMidnight)
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        do {
            try self.init(
                startMinutesAfterMidnight: start,
                endMinutesAfterMidnight: end,
                label: label
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid dining-hours interval: \(start)-\(end)"
            ))
        }
    }
}

enum DiningHoursModelError: Error, Sendable, Equatable {
    case invalidInterval(start: Int, end: Int)
}

enum DiningHoursLoadPolicy: Sendable, Equatable {
    case cacheOnly
    case revalidateIfNeeded
    case forceRevalidation
}

extension DateOnly {
    func addingDays(_ value: Int) -> DateOnly? {
        let calendar = Calendar.gregorian(in: .gmt)
        guard let date = date(in: .gmt),
              let result = calendar.date(byAdding: .day, value: value, to: date) else {
            return nil
        }
        return DateOnly(result, in: .gmt)
    }

    func weekday() -> DiningWeekday? {
        let calendar = Calendar.gregorian(in: .gmt)
        guard let date = date(in: .gmt) else { return nil }
        return DiningWeekday(rawValue: calendar.component(.weekday, from: date))
    }
}

extension Calendar {
    static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
