package com.ryannair05.meetandeat.dining

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.util.concurrent.atomic.AtomicInteger

class DiningProgressTest {
    private val date = LocalDate.of(2026, 9, 28)
    private fun page(meal: String) = """
        <select id="selMeal">
          <option value="Breakfast" selected>Breakfast</option>
          <option value="Lunch">Lunch</option><option value="Dinner">Dinner</option>
        </select>
        <div class="menu-category-section"><h2 class="nutrition-category-title">Entrees</h2>
          <div class="daily-menu-item"><a class="daily-menu-item__link" href="/detail?mid=$meal">$meal food</a></div>
        </div>
    """.trimIndent()

    @Test fun desiredMealAppearsWhileSlowerSiblingIsStillLoading() = runBlocking {
        val lunchReady = CompletableDeferred<MenuDaySnapshot>()
        val releaseDinner = CompletableDeferred<Unit>()
        val source = PennStateDiningSource(transport = { _, _, body ->
            when {
                body!!.contains("selMeal=Dinner") -> { releaseDinner.await(); page("Dinner") }
                body.contains("selMeal=Lunch") -> page("Lunch")
                else -> page("Breakfast")
            }
        })
        val task = async {
            source.loadMenu(PSUDiningHall.NORTH, date, "period-lunch", onPartial = { snapshot ->
                if (snapshot.meals.any { it.id == "period-lunch" && it.sections.isNotEmpty() }) lunchReady.complete(snapshot)
            })
        }
        val preview = withTimeout(2_000) { lunchReady.await() }
        assertFalse(task.isCompleted)
        assertEquals(listOf("Breakfast", "Lunch", "Dinner"), preview.meals.map { it.name })
        assertEquals(setOf("period-dinner"), preview.pendingMealIds)
        releaseDinner.complete(Unit)
        assertTrue(task.await().pendingMealIds.isEmpty())
    }

    @Test fun aFailedMealDoesNotCancelOtherMealsOrPretendTheDayIsComplete() = runBlocking {
        val releaseLunch = CompletableDeferred<Unit>()
        val dinnerFailed = CompletableDeferred<Unit>()
        val previews = mutableListOf<MenuDaySnapshot>()
        val source = PennStateDiningSource(transport = { _, _, body ->
            when {
                body!!.contains("selMeal=Dinner") -> { dinnerFailed.complete(Unit); error("offline") }
                body.contains("selMeal=Lunch") -> { releaseLunch.await(); page("Lunch") }
                else -> page("Breakfast")
            }
        })
        val task = async { runCatching { source.loadMenu(PSUDiningHall.NORTH, date, onPartial = { previews.add(it) }) } }
        dinnerFailed.await()
        releaseLunch.complete(Unit)
        assertTrue(task.await().isFailure)
        val retained = previews.last()
        assertEquals(setOf("period-dinner"), retained.pendingMealIds)
        assertTrue(retained.meals.first { it.id == "period-lunch" }.sections.isNotEmpty())
    }

    @Test fun joinedCallersReceiveProgressAndOneCancellationDoesNotCancelSharedFetch() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val pool = MenuRequests(scope)
            val calls = AtomicInteger()
            val preview = MenuDaySnapshot(hallId = "north", date = date.toString(), fetchedAtEpochMillis = 1,
                meals = emptyList(), pendingMealIds = setOf("dinner"))
            val done = preview.copy(pendingMealIds = emptySet())
            val release = CompletableDeferred<Unit>()
            val firstSaw = CompletableDeferred<Unit>()
            val secondSaw = CompletableDeferred<Unit>()
            val first = async {
                pool.load("north", { firstSaw.complete(Unit) }) { publish ->
                    calls.incrementAndGet(); publish(preview); release.await(); done
                }
            }
            firstSaw.await()
            val second = async {
                pool.load("north", { assertEquals(preview, it); secondSaw.complete(Unit) }) { error("Duplicate request") }
            }
            withTimeout(1_000) { secondSaw.await() }
            first.cancelAndJoin()
            release.complete(Unit)
            assertEquals(done, second.await())
            assertEquals(1, calls.get())
        } finally { scope.cancel() }
    }

    @Test fun failureRetainsLatestPreviewAndANewRequestCanRetry() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val pool = MenuRequests(scope)
            val preview = MenuDaySnapshot(hallId = "north", date = date.toString(), fetchedAtEpochMillis = 1,
                meals = emptyList(), pendingMealIds = setOf("dinner"))
            var last: MenuDaySnapshot? = null
            val result = runCatching {
                pool.load("north", { last = it }) { publish -> publish(preview); error("offline") }
            }
            assertTrue(result.isFailure)
            assertEquals(preview, last)
            val complete = preview.copy(pendingMealIds = emptySet())
            assertEquals(complete, pool.load("north", {}) { complete })
        } finally { scope.cancel() }
    }

    @Test fun temporarilyEmptyMealsRemainInTheCompletedPicker() = runBlocking {
        val source = PennStateDiningSource(transport = { _, _, body ->
            if (body!!.contains("selMeal=Lunch") || body.contains("selMeal=Dinner")) "No menu items"
            else page("Breakfast")
        })
        val result = source.loadMenu(PSUDiningHall.NORTH, date)
        assertEquals(listOf("Breakfast", "Lunch", "Dinner"), result.meals.map { it.name })
        assertTrue(result.meals.first().sections.isNotEmpty())
        assertTrue(result.meals.drop(1).all { it.sections.isEmpty() })
        assertTrue(result.pendingMealIds.isEmpty())
    }

    @Test fun explicitClosureIsNotReportedAsUnavailable() {
        val status = DayHours(emptyList(), explicitlyClosed = true).serviceStatus("Lunch", date)
        assertEquals(DiningServiceStatusKind.CLOSED, status.kind)
    }
}
