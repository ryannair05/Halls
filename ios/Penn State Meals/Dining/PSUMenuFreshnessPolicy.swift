import Foundation

enum PSUMenuFreshnessPolicy {
    private static let fallbackFreshnessLifetime: TimeInterval = 4 * 60 * 60

    static func isStale(
        _ snapshot: MenuDaySnapshot,
        at now: Date,
        dayHours: DayHours?,
        calendarContext: ProviderCalendarContext = ProviderCalendarContexts.pennState
    ) -> Bool {
        guard snapshot.fetchedAt <= now else { return false }

        let today = calendarContext.serviceDate(containing: now)
        let menuDate = snapshot.key.localDate
        if menuDate < today { return false }
        if menuDate > today {
            guard menuDate == today.addingDays(1) else { return false }
            return calendarContext.serviceDate(containing: snapshot.fetchedAt) < today
        }

        guard calendarContext.serviceDate(containing: snapshot.fetchedAt) == today else {
            return true
        }
        guard let dayHours else {
            return now.timeIntervalSince(snapshot.fetchedAt) >= fallbackFreshnessLifetime
        }
        return dayHours.intervals.contains { interval in
            guard let boundary = calendarContext.date(
                on: today,
                minutesAfterMidnight: interval.startMinutesAfterMidnight
            ) else { return false }
            return snapshot.fetchedAt < boundary && boundary <= now
        }
    }
}
