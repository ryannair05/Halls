package com.ryannair05.meetandeat.discover

import org.junit.Assert.*
import org.junit.Test

class DiscoverBehaviorTest {
    @Test fun campusClassificationUsesEvidenceNotDescription() {
        val club = CampusOrganization("c", "Café Club")
        val json = sampleEvent()
        val unrelated = json.copy(id = "other", organizationIds = listOf("elsewhere"), description = "University Park")
        val calendar = json.copy(id = "ical", source = EventSource.CALENDAR, organizationIds = emptyList(), hostNames = listOf("Cafe Club"))
        val explicit = calendar.copy(id = "location", hostNames = emptyList(), location = "State College, PA")
        val casual = explicit.copy(id = "prose", location = "Elsewhere", description = "Meet our University Park friends")
        val result = classifyCampus(listOf(json, unrelated, calendar, explicit, casual), listOf(club))
        assertEquals(listOf("e", "ical", "location"), result.map { it.id })
        assertEquals(listOf("c"), result[1].organizationIds)
    }
    @Test fun dateFiltersUseCampusDayAndDstBoundaries() {
        val now = at("2026-11-01T04:30:00Z") // DST fall-back day in Pennsylvania.
        val lateToday = sampleEvent(start = at("2026-11-02T04:30:00Z"), end = at("2026-11-02T04:45:00Z"))
        val tomorrow = sampleEvent(start = at("2026-11-02T05:00:00Z"), end = null)
        assertTrue(DiscoverDate.TODAY.includes(lateToday, now)); assertFalse(DiscoverDate.TODAY.includes(tomorrow, now))
        assertTrue(DiscoverDate.TOMORROW.includes(tomorrow, now))
        val sunday = sampleEvent(start = at("2026-10-04T04:00:00Z"), end = null)
        assertFalse(DiscoverDate.WEEK.includes(sunday, at("2026-09-28T12:00:00Z")))
    }
    @Test fun filtersComposeOnHomeAndBrowseWhileHomeIgnoresSearchText() {
        val now = at("2026-09-28T12:00:00Z")
        val event = sampleEvent().copy(benefits = listOf("Free Food"), categories = listOf("Arts"), location = "Online")
        val filters = DiscoverFilters(freeFood = true, eventCategory = "Arts", onlineOnly = true, savedClubsOnly = true, eventQuery = "cafe")
        val saved = DiscoverSaved(organizations = mapOf("c" to CampusOrganization("c", "Club")))
        assertTrue(matchesEvent(event, filters, saved, now, false, "cafe event"))
        assertFalse(matchesEvent(event, filters, DiscoverSaved(), now, false, "cafe event"))
        assertTrue(matchesEvent(event, filters.copy(eventQuery = "unmatched"), saved, now, true, ""))
        assertFalse(matchesEvent(event, filters.copy(eventCategory = "other"), saved, now, true, ""))
        assertFalse(matchesEvent(event, filters, DiscoverSaved(), now, true, ""))
        assertFalse(matchesEvent(event.copy(location = "HUB"), filters, saved, now, true, ""))
        assertFalse(matchesEvent(event.copy(cancelled = true), filters, saved, now, true, ""))
    }
    @Test fun browsingAllEventsPreservesHomeFiltersAndSelectedDate() {
        val filters = DiscoverFilters(homeDate = DiscoverDate.TOMORROW, freeFood = true,
            eventCategory = "Arts", onlineOnly = true, savedClubsOnly = true, eventQuery = "old search")
        val browse = filters.forEventBrowse()
        assertEquals(DiscoverDate.TOMORROW, browse.date)
        assertEquals("", browse.eventQuery)
        assertEquals("Arts", browse.eventCategory)
        assertTrue(browse.freeFood && browse.onlineOnly && browse.savedClubsOnly)
    }
    @Test fun resetClearsRefinementsWithoutErasingSearchOrOtherScreenDate() {
        val filters = DiscoverFilters(homeDate = DiscoverDate.TOMORROW, date = DiscoverDate.UPCOMING,
            eventQuery = "music", freeFood = true, eventCategory = "Arts", onlineOnly = true, savedClubsOnly = true)
        val home = filters.resetEventFilters(home = true)
        assertEquals(DiscoverDate.TODAY, home.homeDate); assertEquals(DiscoverDate.UPCOMING, home.date)
        assertEquals("music", home.eventQuery); assertEquals("", home.eventCategory)
        assertFalse(home.freeFood || home.onlineOnly || home.savedClubsOnly)
        val browse = filters.resetEventFilters(home = false)
        assertEquals(DiscoverDate.WEEK, browse.date); assertEquals(DiscoverDate.TOMORROW, browse.homeDate)
    }
    @Test fun savedMergeKeepsPastAndMissingItemsWhileRefreshingMatches() {
        val old = sampleEvent(); val past = sampleEvent("past", 0, 1)
        val saved = DiscoverSaved(events = mapOf(old.id to old, past.id to past))
        val merged = saved.merge(DiscoverSnapshot(events = listOf(old.copy(cancelled = true))))
        assertTrue(merged.events.getValue(old.id).cancelled); assertEquals(past, merged.events["past"])
    }
    @Test fun calendarDraftPreservesAllDayDatesAndProvidesMissingEnd() {
        val event = sampleEvent(start = at("2026-11-01T04:00:00Z"), end = at("2026-11-02T05:00:00Z")).copy(allDay = true)
        val draft = calendarDraft(event)
        assertEquals(at("2026-11-01T00:00:00Z"), draft.start); assertEquals(at("2026-11-02T00:00:00Z"), draft.end)
        val timed = sampleEvent(end = null); assertEquals(timed.start + 3_600_000L, calendarDraft(timed).end)
    }
    @Test fun directionsUseValidCoordinatesOrEncodedCampusLocation() {
        assertTrue(directionsUrl(sampleEvent().copy(latitude = 40.8, longitude = -77.8)).contains("40.8%2C-77.8"))
        val fallback = directionsUrl(sampleEvent().copy(latitude = 200.0, longitude = 0.0, location = "HUB & Lawn"))
        assertTrue(fallback.contains("HUB%20%26%20Lawn")); assertTrue(fallback.contains("walking"))
    }
}
