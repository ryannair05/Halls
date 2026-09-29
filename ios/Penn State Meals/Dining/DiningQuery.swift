import Foundation

enum DiningQueryError: Error, Sendable {
    case calendarProviderMismatch(expected: DiningProviderID, actual: DiningProviderID)
    case dateOutsideHorizon(DateOnly)
}

/// One immutable menu selection. Cache identity remains `MenuDayKey`; service-period selection is
/// presentation state and deliberately does not split repository entries.
struct DiningQuery: Sendable {
    let locationID: DiningLocationID
    let localDate: DateOnly
    let servicePeriodID: DiningServicePeriodID?
    let sourceVariant: String
    let calendarContext: ProviderCalendarContext

    init(
        locationID: DiningLocationID,
        localDate: DateOnly,
        servicePeriodID: DiningServicePeriodID? = nil,
        sourceVariant: String = MenuDayKey.officialSourceVariant,
        calendarContext: ProviderCalendarContext
    ) throws(DiningQueryError) {
        guard calendarContext.providerID == locationID.provider else {
            throw .calendarProviderMismatch(
                expected: locationID.provider,
                actual: calendarContext.providerID
            )
        }
        self.locationID = locationID
        self.localDate = localDate
        self.servicePeriodID = servicePeriodID
        self.sourceVariant = sourceVariant
        self.calendarContext = calendarContext
    }

    init(
        key: MenuDayKey,
        servicePeriodID: DiningServicePeriodID? = nil,
        calendarContext: ProviderCalendarContext
    ) throws(DiningQueryError) {
        try self.init(
            locationID: key.locationID,
            localDate: key.localDate,
            servicePeriodID: servicePeriodID,
            sourceVariant: key.sourceVariant,
            calendarContext: calendarContext
        )
    }

    /// A nonthrowing construction path for a statically typed hall. The hall conformance owns
    /// both values, so the provider/calendar relationship is guaranteed by the implementation
    /// rather than by runtime source data.
    init(
        hall: PSUDiningHall,
        localDate: DateOnly,
        servicePeriodID: DiningServicePeriodID? = nil,
        sourceVariant: String = MenuDayKey.officialSourceVariant
    ) {
        locationID = hall.locationID
        self.localDate = localDate
        self.servicePeriodID = servicePeriodID
        self.sourceVariant = sourceVariant
        calendarContext = hall.calendarContext
    }

    var menuDayKey: MenuDayKey {
        MenuDayKey(
            locationID: locationID,
            localDate: localDate,
            sourceVariant: sourceVariant
        )
    }

    func selecting(
        date: DateOnly,
        relativeTo instant: Date
    ) throws(DiningQueryError) -> DiningQuery {
        guard calendarContext.contains(date, relativeTo: instant) else {
            throw .dateOutsideHorizon(date)
        }
        return DiningQuery(
            validatedLocationID: locationID,
            localDate: date,
            servicePeriodID: servicePeriodID,
            sourceVariant: sourceVariant,
            calendarContext: calendarContext
        )
    }

    func selecting(servicePeriodID: DiningServicePeriodID?) -> DiningQuery {
        DiningQuery(
            validatedLocationID: locationID,
            localDate: localDate,
            servicePeriodID: servicePeriodID,
            sourceVariant: sourceVariant,
            calendarContext: calendarContext
        )
    }

    private init(
        validatedLocationID: DiningLocationID,
        localDate: DateOnly,
        servicePeriodID: DiningServicePeriodID?,
        sourceVariant: String,
        calendarContext: ProviderCalendarContext
    ) {
        locationID = validatedLocationID
        self.localDate = localDate
        self.servicePeriodID = servicePeriodID
        self.sourceVariant = sourceVariant
        self.calendarContext = calendarContext
    }

}
