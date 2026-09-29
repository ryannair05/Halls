package com.ryannair05.meetandeat.discover

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

private class MemoryStore(var value: DiscoverCache = DiscoverCache()) : DiscoverStore {
    var savedValue = DiscoverSaved()
    override fun cache() = value
    override fun writeCache(value: DiscoverCache) { this.value = value }
    override fun saved() = savedValue
    override fun writeSaved(value: DiscoverSaved) { savedValue = value }
}
class DiscoverRepositoryTest {
    @get:Rule val folder = TemporaryFolder()
    private val eventJson = """{"id":42,"name":"Campus lunch","visibility":"Public","status":"Approved","startsOn":"2026-09-28T17:00:00Z","endsOn":"2026-09-28T19:00:00Z","organizationIds":["1"]}"""
    @Test fun paginationHonorsPageCapAndLimitsConcurrency() = runBlocking {
        val active = AtomicInteger(); val max = AtomicInteger()
        fun page(offset: Int) = DiscoverPage(19, (offset until minOf(offset + 2, 19)).map { mapOf<String, Any?>("id" to it.toString()) })
        val result = allPages(page(0), "id") { offset ->
            val count = active.incrementAndGet(); max.updateAndGet { maxOf(it, count) }
            delay(10); active.decrementAndGet(); page(offset)
        }
        assertEquals(19, result.size); assertTrue(max.get() <= 4); assertTrue(max.get() > 1)
    }
    @Test fun repeatedAndIncompletePagesAreRejected() = runBlocking {
        val first = DiscoverPage(3, listOf(mapOf<String, Any?>("id" to "a")))
        assertTrue(runCatching { allPages(first, "id") { first } }.isFailure)
        assertTrue(runCatching { allPages(first, "id") { DiscoverPage(3, emptyList()) } }.isFailure)
        assertEquals(emptyList<Map<String, Any?>>(), allPages(DiscoverPage(0, emptyList()), "id") { error("Unexpected request") })
    }
    @Test fun jsonFailureFallsBackAndRemembersCapability() = runBlocking {
        val jsonCalls = AtomicInteger()
        val http = DiscoverHttp { path, _ -> when (path) {
            "/api/discovery/search/organizations" -> DiscoverResponse(pageJson(clubJson), "application/json")
            "/api/discovery/event/search" -> { jsonCalls.incrementAndGet(); error("Unavailable") }
            else -> DiscoverResponse(feed(calendarEvent), "text/calendar")
        } }
        val store = MemoryStore(); val repo = DiscoverRepository(store, http)
        val now = at("2026-09-28T12:00:00Z")
        val result = repo.refresh(now = now)
        assertEquals(EventSource.CALENDAR, result.snapshot.eventSource); assertEquals(1, result.snapshot.events.size)
        repo.refresh(true, now + 1_000)
        assertEquals(1, jsonCalls.get()); assertEquals(false, store.value.jsonAvailable)
        repo.refresh(true, now + 24 * 3_600_000L)
        assertEquals(2, jsonCalls.get())
    }
    @Test fun offlineRefreshKeepsCachedDataAndReportsErrors() = runBlocking {
        val snapshot = DiscoverSnapshot(events = listOf(sampleEvent()), eventsUpdated = 1, organizations = listOf(CampusOrganization("c", "Club")), directoryComplete = true)
        val repo = DiscoverRepository(MemoryStore(DiscoverCache(snapshot = snapshot)), DiscoverHttp { _, _ -> error("Offline") })
        val result = repo.refresh(true)
        assertEquals(snapshot.events, result.snapshot.events); assertEquals(snapshot.organizations, result.snapshot.organizations)
        assertEquals(2, result.issues.size)
    }
    @Test fun recoveringDirectoryMakesPreviouslyUnclassifiedEventsVisible() = runBlocking {
        val now = at("2026-09-28T12:00:00Z")
        var directoryAvailable = false
        val http = DiscoverHttp { path, _ ->
            when (path) {
                "/api/discovery/search/organizations" -> {
                    check(directoryAvailable) { "Directory offline" }
                    DiscoverResponse(pageJson(clubJson), "application/json")
                }
                "/api/discovery/event/search" -> DiscoverResponse(pageJson(eventJson), "application/json")
                else -> error("Unexpected path: $path")
            }
        }
        val store = DiscoverFileStore(folder.newFolder())
        val unavailable = DiscoverRepository(store, http).refresh(now = now)
        assertTrue(unavailable.snapshot.events.isEmpty())
        assertTrue(unavailable.issues.any { it.startsWith("Clubs:") })
        directoryAvailable = true
        // Restart from disk within the event TTL: recovery must not wait fifteen minutes.
        val recovered = DiscoverRepository(store, http).refresh(now = now + 1_000)
        assertTrue(recovered.issues.isEmpty())
        assertEquals(listOf("1"), recovered.snapshot.organizations.map { it.id })
        assertEquals(listOf("42"), recovered.snapshot.events.map { it.id })
    }
    @Test fun partialDirectoryDoesNotReplaceCompleteCache() = runBlocking {
        val now = at("2026-09-28T12:00:00Z")
        val old = CampusOrganization("old", "Old club")
        val store = MemoryStore(DiscoverCache(snapshot = DiscoverSnapshot(organizations = listOf(old), directoryComplete = true, eventsUpdated = now), pagingAvailable = false, pagingChecked = now))
        val repo = DiscoverRepository(store, DiscoverHttp { path, _ ->
            when (path) {
                "/api/discovery/search/organizations" -> DiscoverResponse(pageJson(clubJson, 20), "application/json")
                "/api/discovery/event/search" -> DiscoverResponse(pageJson("", 0), "application/json")
                else -> error("Unexpected path: $path")
            }
        })
        val result = repo.refresh(now = now)
        assertEquals(listOf(old), result.snapshot.organizations); assertTrue(result.snapshot.directoryComplete)
        assertTrue(result.issues.single().contains("Limited"))
    }
    @Test fun freshCacheAvoidsNetworkAndConcurrentRefreshesCoalesce() = runBlocking {
        val now = at("2026-09-28T12:00:00Z")
        val count = AtomicInteger()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val store = MemoryStore(DiscoverCache(snapshot = DiscoverSnapshot(eventsUpdated = now, organizationsUpdated = now)))
        val repo = DiscoverRepository(store, DiscoverHttp { path, _ ->
            count.incrementAndGet()
            entered.complete(Unit)
            release.await()
            when (path) {
                "/api/discovery/search/organizations" -> DiscoverResponse(pageJson(clubJson), "application/json")
                "/api/discovery/event/search" -> DiscoverResponse(pageJson(eventJson), "application/json")
                else -> error("Unexpected path: $path")
            }
        })
        repo.refresh(now = now); assertEquals(0, count.get())
        coroutineScope {
            val first = async { repo.refresh(true, now) }
            withTimeout(1_000) { entered.await() }
            val second = async(start = CoroutineStart.UNDISPATCHED) { repo.refresh(true, now) }
            release.complete(Unit)
            awaitAll(first, second).forEach { result ->
                assertEquals(listOf("1"), result.snapshot.organizations.map { it.id })
                assertEquals(listOf("42"), result.snapshot.events.map { it.id })
            }
        }
        assertEquals(2, count.get())
    }
    @Test fun savedItemsRoundTripAndCorruptReadsLeaveOriginalFileIntact() {
        val dir = folder.newFolder(); val store = DiscoverFileStore(dir)
        val saved = DiscoverSaved(events = mapOf("e" to sampleEvent()), organizations = mapOf("c" to CampusOrganization("c", "Café")))
        store.writeSaved(saved); assertEquals(saved, store.saved())
        val file = File(dir, "saved-v1.json"); file.writeText("{broken")
        assertTrue(runCatching { store.saved() }.isFailure); assertEquals("{broken", file.readText())
        File(dir, "cache-v1.json").writeText("{broken")
        assertEquals(DiscoverCache(), store.cache())
    }
}
