package com.ryannair05.meetandeat.cata

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class CataRouteLoadingTest {
    @get:Rule val folder = TemporaryFolder()
    private val routes = listOf(RouteModel(51, "Blue Loop", "BL", "FFFFFF", "0000FF", "Route51.kml", 1))

    @Test fun completedRoutesRefreshAfterExpiryAndOnExplicitRetry() = runBlocking {
        var now = 1_000L
        val loader = SelectedRouteRequests(this) { now }
        var calls = 0
        suspend fun request(force: Boolean = false) {
            loader.start("Route51.kml", 51, force) { calls++; true }
            yield()
        }
        request()
        request()
        assertEquals(1, calls)
        now += 60 * 60 * 1_000L
        request()
        assertEquals(2, calls)
        request(force = true)
        assertEquals(3, calls)
    }

    @Test fun existingMoshiCatalogAndStopFilesRemainReadable() = runBlocking {
        val file = File(folder.newFolder(), "routes.json")
        file.writeText("""{"fetchedAt":1000,"routes":[{"RouteId":51,"LongName":"Blue Loop","RouteAbbreviation":"BL","TextColor":"FFFFFF","Color":"0000FF","RouteTraceFilename":"Route51.kml","SortOrder":1}]}""")
        CataRouteCatalog(file, { 1_001 }) { error("Unexpected network") }.load(false) { assertEquals(routes, it) }
        val stops = kotlinx.serialization.json.Json.decodeFromString<List<StopJson>>("""[{"Name":"Pattee","Latitude":40.79,"Longitude":-77.86,"StopId":4}]""")
        assertEquals(4, stops.single().id)
    }

    @Test fun expiredCatalogPublishesSavedRoutesBeforeNetworkCompletes() = runBlocking {
        val file = File(folder.newFolder(), "routes.json")
        var now = 1_000L
        CataRouteCatalog(file, { now }) { routes }.load(false) {}
        now += 60 * 60 * 1_000L
        val published = CompletableDeferred<Unit>()
        val networkStarted = CompletableDeferred<Unit>()
        val releaseNetwork = CompletableDeferred<Unit>()
        val catalog = CataRouteCatalog(file, { now }) {
            assertTrue(published.isCompleted)
            networkStarted.complete(Unit)
            releaseNetwork.await()
            routes
        }
        val job = launch { catalog.load(false) { assertEquals(routes, it); published.complete(Unit) } }
        withTimeout(1_000) { networkStarted.await() }
        assertTrue(published.isCompleted)
        assertTrue(job.isActive)
        releaseNetwork.complete(Unit)
        job.join()
    }

    @Test fun offlineRefreshRetainsSavedCatalogAndEmptyResponseCannotOverwriteIt() = runBlocking {
        val file = File(folder.newFolder(), "routes.json")
        CataRouteCatalog(file, { 1_000 }) { routes }.load(false) {}
        val disk = file.readText()
        var displayed = emptyList<RouteModel>()
        val offline = CataRouteCatalog(file, { 1_000 }) { error("offline") }
        assertTrue(runCatching { offline.load(true) { displayed = it } }.isFailure)
        assertEquals(routes, displayed)
        val empty = CataRouteCatalog(file, { 1_000 }) { emptyList() }
        displayed = emptyList()
        assertTrue(runCatching { empty.load(true) { displayed = it } }.isFailure)
        assertEquals(disk, file.readText())
    }

    @Test fun freshCatalogAvoidsNetworkAndWriteFailureDoesNotLoseRoutes() = runBlocking {
        val file = File(folder.newFolder(), "routes.json")
        CataRouteCatalog(file, { 1_000 }) { routes }.load(false) {}
        CataRouteCatalog(file, { 1_001 }) { error("Unexpected network") }.load(false) { assertEquals(routes, it) }
        val unwritable = File(folder.newFile(), "routes.json")
        var displayed = emptyList<RouteModel>()
        CataRouteCatalog(unwritable, { 1_000 }) { routes }.load(false) { displayed = it }
        assertEquals(routes, displayed)
    }

    @Test fun metadataRefreshDoesNotDuplicateRouteLoadsAndDeselectCancelsWork() = runBlocking {
        val loader = SelectedRouteRequests(this)
        val started = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        var calls = 0
        loader.start("Route51.kml", 51) {
            calls++; started.complete(Unit)
            try { awaitCancellation() } finally { cancelled.complete(Unit) }
        }
        started.await()
        loader.start("Route51.kml", 51) { calls++; true }
        loader.start("Route51.kml", 51, force = true) { calls++; true }
        assertEquals(1, calls)
        loader.cancel("Route51.kml")
        withTimeout(1_000) { cancelled.await() }
        val reselected = CompletableDeferred<Unit>()
        loader.start("Route51.kml", 51) { calls++; reselected.complete(Unit); true }
        reselected.await()
        yield()
        loader.start("Route51.kml", 51) { error("Completed route should not restart") }
        yield()
        assertEquals(2, calls)
    }
}
