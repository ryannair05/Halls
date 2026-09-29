package com.ryannair05.meetandeat.discover

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Optional read-only smoke test: DISCOVER_LIVE_SMOKE=1 ./gradlew :app:testDebugUnitTest --tests '*DiscoverLiveSourceTest' */
class DiscoverLiveSourceTest {
    @get:Rule val folder = TemporaryFolder()
    @Test fun publicDirectoryEventsAndCalendarFeed() = runBlocking {
        assumeTrue(System.getenv("DISCOVER_LIVE_SMOKE") == "1")
        val http = PublicDiscoverHttp()
        val store = DiscoverFileStore(folder.newFolder())
        val result = DiscoverRepository(store, http).refresh(force = true)
        assertTrue(result.issues.joinToString(), result.issues.isEmpty())
        assertTrue(result.snapshot.directoryComplete)
        assertTrue(result.snapshot.organizations.isNotEmpty())
        assertNotNull(result.snapshot.eventsUpdated)
        val feed = DiscoverCalendar.parse(http.get("/events.ics", emptyMap()).body)
        assertTrue(feed.isNotEmpty())
        println("Verified ${result.snapshot.organizations.size} University Park clubs, ${result.snapshot.events.size} campus events (${result.snapshot.eventSource}), ${feed.size} calendar occurrences.")
    }
}
