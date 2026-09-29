package com.ryannair05.meetandeat.discover

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

internal fun at(value: String) = Instant.parse(value).toEpochMilli()
internal fun sampleEvent(id: String = "e", start: Long = at("2026-09-28T17:00:00Z"), end: Long? = at("2026-09-28T19:00:00Z")) = CampusEvent(id, "Campus lunch", start, end, organizationIds = listOf("c"))
internal val clubJson = """{"Id":1,"Name":"Café Club","Status":"Active","Visibility":"Public","CategoryNames":["University Park Orgs","Arts"],"Description":"<b>Meet</b><script>bad()</script>","WebsiteKey":"cafe","ProfilePicture":"cafe.png"}"""
internal fun pageJson(records: String, count: Int = 1) = """{"@odata.count":$count,"value":[$records]}"""
internal fun feed(body: String) = "BEGIN:VCALENDAR\r\n$body\r\nEND:VCALENDAR"
internal val calendarEvent = """BEGIN:VEVENT
UID:https://discover.psu.edu/event/42
DTSTART;TZID=America/New_York:20260928T130000
DTEND;TZID=America/New_York:20260928T140000
SUMMARY:Campus event
LOCATION:University Park
END:VEVENT"""
class DiscoverParsingTest {
    @Test fun organizationRequiresPublicActiveCampusAndNormalizesMarkup() {
        val row = DiscoverJson.page(pageJson(clubJson)).records.single()
        val club = DiscoverJson.organization(row)!!
        assertEquals("1", club.id); assertEquals("Meet", club.description)
        assertEquals(listOf("Arts"), club.categories)
        assertEquals("cafe club", DiscoverSource.normalized(club.name))
        assertTrue(club.imageUrl!!.contains("preset=med-sq"))
        assertNull(DiscoverJson.organization(row + ("Visibility" to "Private")))
        assertNull(DiscoverJson.organization(row + ("CategoryNames" to listOf("Other campus"))))
        assertNull(DiscoverJson.organization(row + ("Status" to "Inactive")))
    }
    @Test fun eventAcceptsMixedIdsCoordinatesAndFractionalDates() {
        val row = mapOf<String, Any?>("id" to 42.0, "name" to "Lunch", "visibility" to "Public", "status" to "Approved",
            "startsOn" to "2026-09-28T13:00:00.125-04:00", "endsOn" to "2026-09-28T14:00:00-04:00", "organizationIds" to listOf("1", 2.0),
            "organizationId" to "1", "latitude" to "40.8", "longitude" to -77.8, "description" to "<a href='https://psu.zoom.us/j/123'>Join</a>")
        val event = DiscoverJson.event(row)!!
        assertEquals(listOf("1", "2"), event.organizationIds); assertEquals(40.8, event.latitude!!, 0.001)
        assertEquals(at("2026-09-28T17:00:00.125Z"), event.start)
        assertEquals("https://psu.zoom.us/j/123", event.onlineUrl)
        assertNull(DiscoverJson.event(row + ("endsOn" to "2026-01-01T00:00:00Z")))
        assertNull(DiscoverJson.event(row + ("visibility" to "Private")))
        assertTrue(DiscoverJson.event(row + ("status" to "Cancelled"))!!.cancelled)
    }
    @Test fun invalidUnicodeIsNormalizedWithoutDamagingEmoji() {
        assertEquals("Climb 🧗�", DiscoverSource.plain("Climb 🧗\uD83C"))
        assertEquals("Climb 🧗", DiscoverSource.plain("Climb 🧗"))
    }
    @Test fun unsafeAndMalformedLinksAreRejected() {
        assertNull(DiscoverSource.https("javascript:alert(1)"))
        assertNull(DiscoverSource.image("../file.png"))
        assertNull(DiscoverSource.online("<a href='https://zoom.us.evil.test'>Join</a>"))
        assertEquals("https://example.org/meeting", DiscoverSource.online("<a href='https://example.org/meeting'>Join online</a>"))
    }
    @Test fun calendarUnfoldsAndUnescapesMetadata() {
        val body = calendarEvent.replace("SUMMARY:Campus event", "SUMMARY:Campus\\, event\n continued")
            .replace("LOCATION:University Park", "LOCATION:University Park\nCATEGORIES:Arts\\, crafts,Social\nDESCRIPTION:About\\nHosted by: Café Club\\nOnline Location: https://meet.google.com/abc\\nAdditional Information can be found at: https://discover.psu.edu/event/42\nSTATUS:CANCELLED")
        val event = DiscoverCalendar.parse(feed(body)).single()
        assertEquals("42", event.id); assertEquals("Campus, eventcontinued", event.title)
        assertEquals(listOf("Arts, crafts", "Social"), event.categories)
        assertEquals(listOf("Café Club"), event.hostNames); assertEquals("About", event.description)
        assertEquals("https://meet.google.com/abc", event.onlineUrl); assertTrue(event.cancelled)
        assertEquals(at("2026-09-28T17:00:00Z"), event.start)
    }
    @Test fun calendarSupportsAllDayUtcAndDoesNotExpandRecurrence() {
        val allDay = calendarEvent.replace("DTSTART;TZID=America/New_York:20260928T130000", "DTSTART;VALUE=DATE:20260928")
            .replace("DTEND;TZID=America/New_York:20260928T140000", "DTEND;VALUE=DATE:20260930\nRRULE:FREQ=DAILY;COUNT=20")
        val event = DiscoverCalendar.parse(feed(allDay)).single()
        assertTrue(event.allDay); assertTrue(event.ongoing(at("2026-09-29T16:00:00Z")))
        assertFalse(event.upcoming(at("2026-09-30T04:00:00Z")))
        val utc = calendarEvent.replace("DTSTART;TZID=America/New_York:20260928T130000", "DTSTART:20260928T130000Z")
        assertEquals(at("2026-09-28T13:00:00Z"), DiscoverCalendar.parse(feed(utc)).single().start)
    }
    @Test fun calendarEmptyIsValidButMalformedAndInvalidDatesAreNot() {
        assertTrue(DiscoverCalendar.parse(feed("")).isEmpty())
        listOf("html", feed(calendarEvent.replace("END:VEVENT", "")), feed(calendarEvent.replace("20260928T130000", "20261328T130000"))).forEach { bad ->
            assertTrue(runCatching { DiscoverCalendar.parse(bad) }.isFailure)
        }
    }
}
