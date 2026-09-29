package com.ryannair05.meetandeat.dining

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class DiningFiltersTest {
    private fun item(name: String = "Rice bowl", vararg labels: String) =
        DiningMenuItem(id = name, name = name, sourceOrder = 0, sourceLabels = labels.toList())

    @Test fun halalFriendlyKeepsItsLabelAndMatchesHalalFilter() {
        val meal = item("Rice bowl", "Halal Friendly")
        assertEquals(setOf(MenuTrait.HALAL_FRIENDLY), MenuTraitClassifier.classify(meal.sourceLabels, meal.name))
        assertTrue(DietaryFilter(setOf(DietaryRequirement.HALAL)).matches(meal))
    }

    @Test fun multipleRequirementsMustAllBeExplicitlyPublished() {
        val filter = DietaryFilter(setOf(DietaryRequirement.VEGAN, DietaryRequirement.GLUTEN_FRIENDLY))
        assertTrue(filter.matches(item("Rice bowl", "Vegan", "Gluten Free")))
        assertTrue(filter.matches(item("Rice bowl", "Vegan Friendly", "Gluten Friendly - Made W/O Gluten Containing Items")))
        assertFalse(filter.matches(item("Rice bowl", "Vegetarian", "Gluten Free")))
        assertFalse(filter.matches(item("Rice bowl", "Vegan")))
        assertFalse(filter.matches(item("Vegan gluten free rice bowl")))
    }

    @Test fun negativeOrUnrecognizedLabelsDoNotBecomeGlutenClaims() {
        val filter = DietaryFilter(setOf(DietaryRequirement.GLUTEN_FRIENDLY))
        assertFalse(filter.matches(item("Rice bowl", "Not gluten free")))
        assertFalse(filter.matches(item("Rice bowl", "Gluten friendly options available")))
        assertFalse(filter.matches(item("Rice bowl", "May contain wheat")))
    }

    @Test fun pluralNutsGetTheirDietaryIndicator() {
        val traits = MenuTraitClassifier.classify(listOf("Contains almonds, cashews and milk"), "Granola")
        assertTrue(MenuTrait.TREE_NUT in traits)
        assertTrue(MenuTrait.MILK in traits)
        assertFalse(MenuTrait.PEANUT in traits)
    }

    @Test fun clearingDietaryFilterRetainsMenuSearch() {
        val rice = item("Café rice", "Vegan")
        val chicken = item("Café chicken", "Halal")
        val snapshot = MenuDaySnapshot(hallId = "east", date = "2026-09-07", fetchedAtEpochMillis = 0,
            meals = listOf(DiningMealPeriod("lunch", "Lunch", 0,
                listOf(DiningMenuSection("entrees", "Entrees", 0, listOf(rice, chicken))))))
        val state = DiningMenuUiState(PSUDiningHall.EAST, LocalDate.of(2026, 9, 7),
            snapshotState = LoadState.Ready(snapshot), selectedMealId = "lunch",
            searchQuery = "cafe", filter = DietaryFilter(setOf(DietaryRequirement.VEGAN)))
        assertEquals(listOf(rice), state.visibleSections.single().items)
        assertEquals(listOf(rice, chicken), state.copy(filter = DietaryFilter()).visibleSections.single().items)
        assertTrue(state.copy(searchQuery = "chicken").visibleSections.isEmpty())
    }
}
