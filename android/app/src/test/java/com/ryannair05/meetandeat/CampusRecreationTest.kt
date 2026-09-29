package com.ryannair05.meetandeat

import org.junit.Assert.*
import org.junit.Test
import org.jsoup.Jsoup
import java.time.LocalDate

class CampusRecreationTest {
    @Test fun courtRangesAndDoubleDigitsMatchOnlyTheirCourts() {
        assertEquals(setOf(IMFacilityRegion("Gym 3", 2), IMFacilityRegion("Gym 3", 3)), IMFacilityRegion.regions("Gym 3 Courts 2–3"))
        assertEquals(setOf(IMFacilityRegion("Racquetball", 10)), IMFacilityRegion.regions("Racquetball Court 10"))
        assertEquals(3, IMFacilityRegion.regions("Gym 1").size)
        assertEquals(setOf(IMFacilityRegion("Gym 2")), IMFacilityRegion.regions("MAC Court"))
        assertEquals(setOf(IMFacilityRegion("Turf East")), IMFacilityRegion.regions("Turf East"))
    }

    @Test fun weeklyScheduleHonorsExceptionsAndUtcEndAcrossDaylightSaving() {
        val appointment = FacilitySchedules.Appointment("Basketball", "2026-10-25T09:00:00.000", "2026-10-25T10:00:00.000",
            recurrenceRule = "FREQ=WEEKLY;BYDAY=SU,MO,WE;UNTIL=20261102T140000Z",
            recurrenceException = "20261028T090000")
        val result = FacilitySchedules.occurrences(listOf(appointment), "Gym 1", LocalDate.of(2026, 10, 28))
        assertEquals(listOf(4, 5), result.map { it.day })
        assertEquals(listOf("9:00 AM–10:00 AM", "9:00 AM–10:00 AM"), result.map { it.time })
    }

    @Test fun oneOffAndAllDayAppointmentsStayWithinSevenDayWindow() {
        val appointments = listOf(
            FacilitySchedules.Appointment("Open", "2026-09-07T00:00:00", "2026-09-08T00:00:00", allDay = true),
            FacilitySchedules.Appointment("Outside", "2026-09-14T09:00:00", "2026-09-14T10:00:00"),
            FacilitySchedules.Appointment("Earlier", "2026-09-06T09:00:00", "2026-09-06T10:00:00"),
        )
        val result = FacilitySchedules.occurrences(appointments, "Turf West", LocalDate.of(2026, 9, 7))
        assertEquals(1, result.size)
        assertEquals("All Day", result.single().time)
        assertEquals(0, result.single().day)
    }

    @Test fun calendarResolvesRelativeEventLinks() {
        val html = """<div class="CalendarItem"><h3 class="NewsTitle">Monday, Sep 7</h3>
            <div class="CalendarEvent"><a href="/Calendar/Event/123"><div class="EventTime">9 AM</div>
            <div class="EventSubject">Yoga</div></a></div></div>"""
        val first = ScheduleParser.parseCalendar(Jsoup.parse(html)).single()
        assertEquals("https://pennstatecampusrec.org/Calendar/Event/123", first.events.single().link)
    }
}
