import Foundation

struct DiningDateHorizon: Equatable, Sendable {
    let pastDayCount: Int
    let futureDayCount: Int

    init(pastDayCount: Int, futureDayCount: Int) {
        self.pastDayCount = max(0, pastDayCount)
        self.futureDayCount = max(0, futureDayCount)
    }
}

enum ProviderCalendarContextError: Error, Sendable {
    case unsupportedProvider(DiningProviderID)
    case invalidTimeZone(String)
    case invalidServiceDayRollover(Int)
}

/// The complete calendar contract for one dining provider.
///
/// `DateOnly` remains the persisted, timezone-free day representation. This value owns every
/// conversion between an absolute `Date` and that provider-local day so device settings cannot
/// silently change a menu query.
struct ProviderCalendarContext: Equatable, Sendable {
    let providerID: DiningProviderID
    let timeZone: TimeZone
    let serviceDayRolloverMinutes: Int
    let dateHorizon: DiningDateHorizon

    init(
        providerID: DiningProviderID,
        timeZone: TimeZone,
        serviceDayRolloverMinutes: Int,
        dateHorizon: DiningDateHorizon
    ) {
        precondition(
            (0..<1_440).contains(serviceDayRolloverMinutes),
            "Service-day rollover must be within a civil day"
        )
        self.providerID = providerID
        self.timeZone = timeZone
        self.serviceDayRolloverMinutes = serviceDayRolloverMinutes
        self.dateHorizon = dateHorizon
    }

    init(
        providerID: DiningProviderID,
        timeZoneIdentifier: String,
        serviceDayRolloverMinutes: Int,
        dateHorizon: DiningDateHorizon
    ) throws(ProviderCalendarContextError) {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw .invalidTimeZone(timeZoneIdentifier)
        }
        guard (0..<1_440).contains(serviceDayRolloverMinutes) else {
            throw .invalidServiceDayRollover(serviceDayRolloverMinutes)
        }
        self.init(
            providerID: providerID,
            timeZone: timeZone,
            serviceDayRolloverMinutes: serviceDayRolloverMinutes,
            dateHorizon: dateHorizon
        )
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func localDate(containing instant: Date) -> DateOnly {
        DateOnly(instant, in: timeZone)
    }

    func serviceDate(containing instant: Date) -> DateOnly {
        guard serviceDayRolloverMinutes > 0,
              let shifted = calendar.date(
                  byAdding: .minute,
                  value: -serviceDayRolloverMinutes,
                  to: instant
              ) else {
            return localDate(containing: instant)
        }
        return localDate(containing: shifted)
    }

    func date(on date: DateOnly, minutesAfterMidnight: Int) -> Date? {
        guard (0...1_440).contains(minutesAfterMidnight) else { return nil }
        if minutesAfterMidnight == 1_440 {
            return date.addingDays(1)?.date(in: timeZone, hour: 0)
        }
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: date.year,
            month: date.month,
            day: date.day,
            hour: minutesAfterMidnight / 60,
            minute: minutesAfterMidnight % 60
        ))
    }

    func permittedRange(relativeTo instant: Date) -> ClosedRange<DateOnly>? {
        let today = localDate(containing: instant)
        guard let lower = today.addingDays(-dateHorizon.pastDayCount),
              let upper = today.addingDays(dateHorizon.futureDayCount) else {
            return nil
        }
        return lower...upper
    }

    func contains(_ date: DateOnly, relativeTo instant: Date) -> Bool {
        permittedRange(relativeTo: instant)?.contains(date) ?? false
    }
}

enum ProviderCalendarContexts {
    private static let eastern = TimeZone(
        identifier: "America/New_York"
    ).unsafelyUnwrapped
    private static let standardHorizon = DiningDateHorizon(
        pastDayCount: 1,
        futureDayCount: 7
    )

    static let pennState = ProviderCalendarContext(
        providerID: .pennState,
        timeZone: eastern,
        serviceDayRolloverMinutes: 0,
        dateHorizon: standardHorizon
    )

    static let barnardColumbia = ProviderCalendarContext(
        providerID: .barnard,
        timeZone: eastern,
        serviceDayRolloverMinutes: 0,
        dateHorizon: standardHorizon
    )

    static let columbia = ProviderCalendarContext(
        providerID: .columbia,
        timeZone: eastern,
        serviceDayRolloverMinutes: 0,
        dateHorizon: standardHorizon
    )

    static let uga = ProviderCalendarContext(
        providerID: .uga,
        timeZone: eastern,
        serviceDayRolloverMinutes: 0,
        // UGA's official Build Your Plate contract publishes menus up to six days ahead.
        dateHorizon: DiningDateHorizon(pastDayCount: 5, futureDayCount: 6)
    )

    static func context(
        for provider: DiningProviderID
    ) throws(ProviderCalendarContextError) -> ProviderCalendarContext {
        switch provider {
        case .pennState: pennState
        case .barnard: barnardColumbia
        case .columbia: columbia
        case .uga: uga
        default: throw .unsupportedProvider(provider)
        }
    }
}
