package com.ryannair05.meetandeat.dining

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDateTime

class MenuFreshnessTest {
    private fun time(value: String) = LocalDateTime.parse(value).atZone(PennStateZone).toInstant().toEpochMilli()
    private fun meal(name: String) = DiningMealPeriod(name, name, 0,
        listOf(DiningMenuSection("entrees", "Entrees", 0, listOf(DiningMenuItem(name, name, sourceOrder = 0)))))
    private fun snapshot(fetched: String = "2026-09-28T08:00") = MenuDaySnapshot(
        hallId = "north", date = "2026-09-28", fetchedAtEpochMillis = time(fetched),
        meals = listOf(meal("Breakfast"), meal("Lunch"), meal("Dinner")))
    private val hours = DayHours(listOf(DiningHoursInterval(7 * 60, 10 * 60), DiningHoursInterval(11 * 60, 14 * 60)))

    @Test fun yesterdayEveningFetchCannotKeepTodaysBreakfastOnlyMenuFresh() {
        val saved = snapshot("2026-09-27T20:00").copy(meals = listOf(meal("Breakfast")))
        assertTrue(menuIsStale(saved, hours, time("2026-09-28T08:00")))
    }

    @Test fun fullMenuStaysFreshUntilNextMealStarts() {
        assertFalse(menuIsStale(snapshot(), hours, time("2026-09-28T10:59")))
        assertTrue(menuIsStale(snapshot(), hours, time("2026-09-28T11:00")))
    }

    @Test fun sparseMenuRetriesAfterFifteenMinutes() {
        val saved = snapshot().copy(meals = listOf(meal("Breakfast")))
        assertFalse(menuIsStale(saved, hours, time("2026-09-28T08:14")))
        assertTrue(menuIsStale(saved, hours, time("2026-09-28T08:15")))
        val emptyLunch = snapshot().copy(meals = listOf(meal("Breakfast"), meal("Lunch").copy(sections = emptyList())))
        assertTrue(menuIsStale(emptyLunch, hours, time("2026-09-28T08:15")))
    }

    @Test fun legacyAndIncompleteSnapshotsNeedRevalidation() {
        assertTrue(menuIsStale(snapshot().copy(schemaVersion = 1), hours, time("2026-09-28T08:01")))
        assertTrue(menuIsStale(snapshot().copy(pendingMealIds = setOf("Dinner")), hours, time("2026-09-28T08:01")))
    }

    @Test fun futureMenusRefreshDailyAndHistoricalMenusRemainCached() {
        assertFalse(menuIsStale(snapshot().copy(date = "2026-09-29"), hours, time("2026-09-28T12:00")))
        assertTrue(menuIsStale(snapshot("2026-09-27T20:00").copy(date = "2026-09-29"), hours, time("2026-09-28T08:00")))
        assertFalse(menuIsStale(snapshot().copy(date = "2026-09-27"), hours, time("2026-09-28T12:00")))
    }

    @Test fun unknownHoursExpireAfterFourHours() {
        assertFalse(menuIsStale(snapshot(), null, time("2026-09-28T11:59")))
        assertTrue(menuIsStale(snapshot(), null, time("2026-09-28T12:00")))
    }

    @Test fun progressExpandsBreakfastOnlyPickerWithoutHidingSavedBreakfast() {
        val saved = snapshot().copy(meals = listOf(meal("Breakfast")))
        val discovery = snapshot().copy(meals = snapshot().meals.map { it.copy(sections = emptyList()) },
            pendingMealIds = setOf("Breakfast", "Lunch", "Dinner"))
        val merged = mergeMenuProgress(saved, discovery)
        assertEquals(listOf("Breakfast", "Lunch", "Dinner"), merged.meals.map { it.name })
        assertEquals(saved.meals.first(), merged.meals.first())
        assertEquals(setOf("Lunch", "Dinner"), merged.pendingMealIds)
        val loaded = discovery.copy(meals = snapshot().meals, pendingMealIds = setOf("Dinner"))
        assertEquals(loaded.meals[1], mergeMenuProgress(saved, loaded).meals[1])
        assertEquals(discovery, mergeMenuProgress(saved.copy(date = "2026-09-27"), discovery))
    }
}
