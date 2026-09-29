package com.ryannair05.meetandeat.dining

import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.LocalDate
import java.util.concurrent.atomic.AtomicInteger

class DiningHoursStoreTest {
    @get:Rule val folder = TemporaryFolder()
    private val moshi = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build()
    private val monday = LocalDate.of(2026, 9, 28)
    private val json = """[
      {"dining_location":"Northside @ Warnock Commons","dining_area":"North Food District",
       "hours":[{"day":"Monday","start":"07:00:00-04:00","end":"11:00:00-04:00","timezone":"America/New_York","comment":"Breakfast"}]},
      {"dining_location":"Greens + Grains @ Market North","dining_area":"North Food District",
       "hours":[{"day":"Monday","start":null,"end":null,"timezone":"America/New_York","comment":"Closed"}]}
    ]"""

    @Test fun persistsForOneWeekAcrossRestartAndPublishesStationsTogether() = runBlocking {
        var now = 1_000L
        val file = File(folder.newFolder(), "hours.json")
        val calls = AtomicInteger()
        fun store() = PennStateHoursStore(file, moshi, { now }, this) { calls.incrementAndGet(); json }
        val first = store().snapshot(monday)
        assertEquals(420, first.halls[PSUDiningHall.NORTH]!!.intervals.single().startMinutes)
        assertTrue(first.stations[PSUDiningHall.NORTH]!!["greens grains market north"]!!.explicitlyClosed)
        now += (7L * 24 * 60 * 60 * 1_000) - 1
        assertEquals(first, store().snapshot(monday))
        assertEquals(1, calls.get())
        now++
        store().snapshot(monday)
        assertEquals(2, calls.get())
    }

    @Test fun refreshIsSharedAndCacheOnlyNeverWaitsForNetwork() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val count = AtomicInteger()
        val store = PennStateHoursStore(File(folder.newFolder(), "hours.json"), moshi, { 1_000 }, this) {
            count.incrementAndGet(); entered.complete(Unit); release.await(); json
        }
        val first = async { store.snapshot(monday) }
        entered.await()
        val others = List(5) { async { store.snapshot(monday) } }
        val cached = withTimeout(1_000) { store.snapshot(monday, cacheOnly = true) }
        assertNull(cached.halls[PSUDiningHall.NORTH])
        release.complete(Unit)
        val result = first.await()
        others.awaitAll().forEach { assertEquals(result, it) }
        assertEquals(1, count.get())
    }

    @Test fun failureCooldownPreventsFiveSequentialRetriesAndExplicitRetryBypassesIt() = runBlocking {
        var now = 1_000L
        var fail = true
        var calls = 0
        val store = PennStateHoursStore(File(folder.newFolder(), "hours.json"), moshi, { now }, this) {
            calls++; if (fail) error("offline") else json
        }
        PSUDiningHall.entries.forEach { assertNull(store.hours(it, monday)) }
        assertEquals(1, calls)
        fail = false
        assertNotNull(store.snapshot(monday, forceRefresh = true).halls[PSUDiningHall.NORTH])
        now += (7L * 24 * 60 * 60 * 1_000)
        fail = true
        assertNull(store.hours(PSUDiningHall.NORTH, monday))
        assertNull(store.hours(PSUDiningHall.NORTH, monday))
        assertEquals(3, calls)
        now += (15L * 60 * 1_000)
        store.hours(PSUDiningHall.NORTH, monday)
        assertEquals(4, calls)
    }

    @Test fun diskFailureDoesNotDiscardSuccessfulHours() = runBlocking {
        val parentFile = folder.newFile()
        val store = PennStateHoursStore(File(parentFile, "hours.json"), moshi, { 1_000 }, this) { json }
        val result = store.snapshot(monday)
        assertNotNull(result.halls[PSUDiningHall.NORTH])
        assertEquals(result, store.snapshot(monday, cacheOnly = true))
    }

    @Test fun invalidRefreshDoesNotOverwriteValidCache() = runBlocking {
        val file = File(folder.newFolder(), "hours.json")
        var response = json
        val store = PennStateHoursStore(file, moshi, { 1_000 }, this) { response }
        val valid = store.snapshot(monday)
        val original = file.readText()
        for (invalid in listOf("[]", "null", "{}", "garbage", """[{"dining_location":"Unknown","hours":[]}]""")) {
            response = invalid
            assertEquals(valid, store.snapshot(monday, forceRefresh = true))
            assertEquals(original, file.readText())
        }
    }

    @Test fun cancellingOneWaiterDoesNotCancelOtherHallRequests() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val store = PennStateHoursStore(File(folder.newFolder(), "hours.json"), moshi, { 1_000 }, this) {
            started.complete(Unit); release.await(); json
        }
        val first = async { store.snapshot(monday) }
        started.await()
        val second = async { store.snapshot(monday) }
        first.cancelAndJoin()
        release.complete(Unit)
        assertNotNull(second.await().halls[PSUDiningHall.NORTH])
    }

    @Test fun corruptAndFutureCachesAreNotUsed() = runBlocking {
        var now = 10_000L
        val file = File(folder.newFolder(), "hours.json")
        PennStateHoursStore(file, moshi, { now }, this) { json }.snapshot(monday)
        now = 1_000L
        val future = PennStateHoursStore(file, moshi, { now }, this) { error("offline") }
        assertNull(future.snapshot(monday, cacheOnly = true).halls[PSUDiningHall.NORTH])
        file.writeText("broken")
        val recovered = PennStateHoursStore(file, moshi, { now }, this) { json }
        assertNotNull(recovered.snapshot(monday).halls[PSUDiningHall.NORTH])
    }
}
