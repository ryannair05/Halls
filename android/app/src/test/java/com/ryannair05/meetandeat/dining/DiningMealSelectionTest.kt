package com.ryannair05.meetandeat.dining

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class DiningMealSelectionTest {
    private val date = LocalDate.of(2026, 9, 21)
    private val breakfast = DiningMealPeriod("breakfast", "Breakfast", 0, emptyList())
    private val dinner = DiningMealPeriod("dinner", "Dinner", 1, emptyList())
    private val snapshot = MenuDaySnapshot(hallId = "north", date = date.toString(), fetchedAtEpochMillis = 0, meals = listOf(breakfast, dinner))
    private val hours = DayHours(listOf(
        DiningHoursInterval(420, 660, "Breakfast"),
        DiningHoursInterval(1020, 1200, "Dinner"),
    ))

    @Test fun firstOpenSelectsCurrentMealInsteadOfFirstServerMeal() {
        assertEquals("dinner", resolveMealSelection(snapshot, date, hours, null, false, date, 1080))
    }

    @Test fun betweenServicesSelectsUpcomingMeal() {
        assertEquals("dinner", resolveMealSelection(snapshot, date, hours, null, false, date, 720))
    }

    @Test fun refreshPreservesExplicitMeal() {
        assertEquals("breakfast", resolveMealSelection(snapshot, date, hours, "breakfast", false, date, 1080))
    }

    @Test fun unresolvedOrMissingSelectionNeverDisplaysAnotherMealsItems() {
        val state = DiningMenuUiState(PSUDiningHall.NORTH, date, snapshotState = LoadState.Ready(snapshot))
        assertNull(state.selectedMeal)
        assertNull(state.copy(selectedMealId = "lunch").selectedMeal)
        assertEquals(dinner, state.copy(selectedMealId = "dinner").selectedMeal)
    }

    @Test fun singlePublishedMealStillHasASelection() {
        assertEquals("dinner", resolveMealSelection(snapshot.copy(meals = listOf(dinner)), date, null, null, false, date, 1080))
    }
}
