package com.ryannair05.meetandeat.dining

import androidx.annotation.DrawableRes
import com.google.android.gms.maps.model.LatLng
import com.ryannair05.meetandeat.R
import kotlinx.serialization.Serializable
import java.text.Normalizer
import java.time.LocalDate
import java.time.Duration
import java.time.ZonedDateTime
import java.time.ZoneId
import java.util.Locale

val PennStateZone: ZoneId = ZoneId.of("America/New_York")

@Serializable
enum class PSUDiningHall(
    val id: String,
    val menuNumber: Int,
    val displayName: String,
    val hoursSourceName: String,
    val latitude: Double,
    val longitude: Double,
    @DrawableRes val imageRes: Int,
) {
    NORTH("north", 17, "North", "Northside @ Warnock Commons", 40.802818, -77.866092, R.drawable.warnock),
    EAST("east", 11, "East", "East Food District Buffet", 40.806427, -77.862289, R.drawable.findlay),
    SOUTH("south", 13, "South", "Southside Buffet @ South Food District", 40.799563, -77.855952, R.drawable.redifer),
    WEST("west", 16, "West", "Waring Square Buffet @ West", 40.795732, -77.867459, R.drawable.waring),
    POLLOCK("pollock", 14, "Pollock", "Pollock Commons Buffet", 40.801819, -77.856322, R.drawable.pollock);

    val coordinate: LatLng get() = LatLng(latitude, longitude)

    companion object {
        fun fromId(id: String): PSUDiningHall? = entries.firstOrNull { it.id == id }
    }
}

@Serializable
data class DiningMenuItem(
    val id: String,
    val name: String,
    val detailUrl: String? = null,
    val sourceOrder: Int,
    val sourceLabels: List<String> = emptyList(),
)

@Serializable
data class DiningMenuSection(
    val id: String,
    val name: String,
    val sourceOrder: Int,
    val items: List<DiningMenuItem>,
)

@Serializable
data class DiningMealPeriod(
    val id: String,
    val name: String,
    val sourceOrder: Int,
    val sections: List<DiningMenuSection>,
)

@Serializable
data class MenuDaySnapshot(
    val schemaVersion: Int = 2,
    val hallId: String,
    val date: String,
    val fetchedAtEpochMillis: Long,
    val meals: List<DiningMealPeriod>,
    @com.squareup.moshi.Json(ignore = true)
    @kotlinx.serialization.Transient
    val isStaleFallback: Boolean = false,
    @com.squareup.moshi.Json(ignore = true)
    @kotlinx.serialization.Transient
    val pendingMealIds: Set<String> = emptySet(),
) {
    val hasPublishedItems: Boolean
        get() = meals.any { meal -> meal.sections.any { it.items.isNotEmpty() } }

    val localDate: LocalDate get() = LocalDate.parse(date)
}

@Serializable
data class NutritionFact(val name: String, val value: String)

@Serializable
data class MenuItemDetail(
    val itemId: String,
    val sourceUrl: String,
    val fetchedAtEpochMillis: Long,
    val ingredients: String? = null,
    val allergenStatement: String? = null,
    val nutrition: List<NutritionFact> = emptyList(),
)

@Serializable
data class DiningHoursInterval(
    val startMinutes: Int,
    val endMinutes: Int,
    val label: String? = null,
)

@Serializable
data class DayHours(
    val intervals: List<DiningHoursInterval> = emptyList(),
    val explicitlyClosed: Boolean = false,
)

enum class DiningServiceStatusKind { OPEN, UPCOMING, CLOSED, UNAVAILABLE }

data class DiningServiceStatus(
    val serviceWindow: String?,
    val status: String,
    val kind: DiningServiceStatusKind,
)

fun DayHours?.serviceStatus(
    mealName: String?,
    date: LocalDate,
    now: ZonedDateTime = ZonedDateTime.now(PennStateZone),
): DiningServiceStatus {
    if (this?.explicitlyClosed == true) {
        return DiningServiceStatus(null, "Closed", DiningServiceStatusKind.CLOSED)
    }
    if (this == null || mealName == null) {
        return DiningServiceStatus(null, "Hours unavailable", DiningServiceStatusKind.UNAVAILABLE)
    }
    val matching = intervals.filter { interval ->
        interval.label?.let { servicePeriodLabelsMatch(mealName, it) } == true
    }
    if (matching.isEmpty()) {
        return DiningServiceStatus(null, "Hours unavailable", DiningServiceStatusKind.UNAVAILABLE)
    }
    val window = matching.joinToString(" · ") {
        "${formatMinutes(it.startMinutes)} – ${formatMinutes(it.endMinutes)}"
    }
    val today = now.withZoneSameInstant(PennStateZone).toLocalDate()
    if (date != today) {
        val dayDistance = java.time.temporal.ChronoUnit.DAYS.between(today, date).toInt()
        val relativeDay = when (dayDistance) {
            1 -> "tomorrow"
            -1 -> "yesterday"
            in 2..Int.MAX_VALUE -> "in $dayDistance days"
            else -> "${-dayDistance} days ago"
        }
        return if (dayDistance > 0) {
            DiningServiceStatus(window, "Opens $relativeDay", DiningServiceStatusKind.UPCOMING)
        } else {
            DiningServiceStatus(window, "Closed $relativeDay", DiningServiceStatusKind.CLOSED)
        }
    }

    val minute = now.withZoneSameInstant(PennStateZone).let { it.hour * 60 + it.minute }
    val current = matching.firstOrNull { minute in it.startMinutes until it.endMinutes }
    if (current != null) {
        return DiningServiceStatus(
            window,
            "Open · Closes ${relativeTime(current.endMinutes, date, now)}",
            DiningServiceStatusKind.OPEN,
        )
    }
    val next = matching.firstOrNull { minute < it.startMinutes }
    return if (next != null) {
        DiningServiceStatus(
            window,
            "Opens ${relativeTime(next.startMinutes, date, now)}",
            DiningServiceStatusKind.UPCOMING,
        )
    } else {
        DiningServiceStatus(window, "Closed", DiningServiceStatusKind.CLOSED)
    }
}

private fun relativeTime(minutesAfterMidnight: Int, date: LocalDate, now: ZonedDateTime): String {
    val eventDate = if (minutesAfterMidnight == 1_440) date.plusDays(1) else date
    val minute = if (minutesAfterMidnight == 1_440) 0 else minutesAfterMidnight
    val event = eventDate.atTime(minute / 60, minute % 60).atZone(PennStateZone)
    val minutes = maxOf(1, (Duration.between(now, event).seconds + 59) / 60)
    if (minutes < 60) return "in $minutes min"
    val hours = minutes / 60
    val remainder = minutes % 60
    return if (remainder == 0L) "in $hours hr" else "in $hours hr $remainder min"
}

enum class DietaryRequirement(val displayName: String) {
    VEGAN("Vegan"),
    HALAL("Halal"),
    GLUTEN_FRIENDLY("Gluten Friendly"),
}

enum class MenuTrait {
    VEGAN,
    VEGETARIAN,
    HALAL,
    HALAL_FRIENDLY,
    GLUTEN_FRIENDLY,
    GLUTEN_FREE,
    ALLERGEN_WARNING,
    MILK,
    EGG,
    FISH,
    SHELLFISH,
    PEANUT,
    TREE_NUT,
    WHEAT,
    SOY,
    SESAME,
    UNKNOWN,
}

data class DietaryFilter(val required: Set<DietaryRequirement> = emptySet()) {
    val isEmpty: Boolean get() = required.isEmpty()

    fun matches(item: DiningMenuItem): Boolean {
        val traits = MenuTraitClassifier.classify(item.sourceLabels, item.name)
        return required.all { requirement ->
            when (requirement) {
                DietaryRequirement.VEGAN -> MenuTrait.VEGAN in traits
                DietaryRequirement.HALAL -> MenuTrait.HALAL in traits || MenuTrait.HALAL_FRIENDLY in traits
                DietaryRequirement.GLUTEN_FRIENDLY ->
                    MenuTrait.GLUTEN_FRIENDLY in traits || MenuTrait.GLUTEN_FREE in traits
            }
        }
    }
}

object MenuTraitClassifier {
    fun classify(labels: List<String>, itemName: String): Set<MenuTrait> {
        val item = normalizeDiningText(itemName)
        return buildSet {
            labels.map(::normalizeDiningText).distinct().filter { it.isNotBlank() && it != item }.forEach { label ->
                when {
                    label == "vegan" || label == "vegan friendly" -> add(MenuTrait.VEGAN)
                    label in setOf("vegetarian", "vegetarian friendly", "meatless", "meat free") -> add(MenuTrait.VEGETARIAN)
                    label == "halal" -> add(MenuTrait.HALAL)
                    label == "halal friendly" -> add(MenuTrait.HALAL_FRIENDLY)
                    label in setOf("gluten free", "gluten gluten free") -> add(MenuTrait.GLUTEN_FREE)
                    label in setOf("gluten friendly", "gluten friendly made w o gluten containing items") -> add(MenuTrait.GLUTEN_FRIENDLY)
                    label.startsWith("contains ") || label.startsWith("may contain ") || label.contains("allergen") -> {
                        add(MenuTrait.ALLERGEN_WARNING)
                        allergens(label).forEach(::add)
                    }
                    label !in setOf("pork", "contains pork", "may contain pork", "contains pork products") -> add(MenuTrait.UNKNOWN)
                }
            }
        }
    }

    fun classifyAllergens(statement: String): Set<MenuTrait> {
        val normalized = normalizeDiningText(statement)
        return buildSet {
            add(MenuTrait.ALLERGEN_WARNING)
            addAll(allergens(normalized))
        }
    }

    private fun allergens(label: String): Set<MenuTrait> = buildSet {
        fun has(vararg words: String) = words.any { Regex("(^| )${Regex.escape(it)}( |$)").containsMatchIn(label) }
        if (has("milk", "dairy")) add(MenuTrait.MILK)
        if (has("egg", "eggs")) add(MenuTrait.EGG)
        if (has("fish")) add(MenuTrait.FISH)
        if (has("shellfish", "crustacean", "crustaceans", "shrimp", "crab", "lobster")) add(MenuTrait.SHELLFISH)
        if (has("peanut", "peanuts")) add(MenuTrait.PEANUT)
        if (label.contains("tree nut") || has("almond", "almonds", "cashew", "cashews", "pecan", "pecans", "pistachio", "pistachios", "walnut", "walnuts", "hazelnut", "hazelnuts")) add(MenuTrait.TREE_NUT)
        if (has("wheat")) add(MenuTrait.WHEAT)
        if (has("soy", "soya", "soybean", "soybeans")) add(MenuTrait.SOY)
        if (has("sesame")) add(MenuTrait.SESAME)
    }
}

fun normalizeDiningText(value: String, separator: String = " "): String {
    val folded = Normalizer.normalize(value, Normalizer.Form.NFD)
        .replace("\\p{M}+".toRegex(), "")
        .lowercase(Locale.US)
        .replace("[^a-z0-9]+".toRegex(), separator)
    return folded.trim(separator.single())
}

data class DiningSearchAppearance(
    val hall: PSUDiningHall,
    val date: LocalDate,
    val mealNames: List<String>,
    val sectionNames: List<String>,
)

data class DiningSearchResult(
    val item: DiningMenuItem,
    val appearances: List<DiningSearchAppearance>,
)

sealed interface LoadState<out T> {
    data object Idle : LoadState<Nothing>
    data class Loading<T>(val cached: T? = null) : LoadState<T>
    data class Ready<T>(val value: T, val isRefreshing: Boolean = false) : LoadState<T>
    data class Empty(val message: String) : LoadState<Nothing>
    data class Error<T>(val message: String, val cached: T? = null) : LoadState<T>
}
