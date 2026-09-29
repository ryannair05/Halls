package com.ryannair05.meetandeat.dining

import java.time.Instant

internal fun menuIsStale(snapshot: MenuDaySnapshot, hours: DayHours?, nowMillis: Long): Boolean {
    // Older caches omitted empty provider meal choices. Display them while rebuilding the full picker.
    if (snapshot.schemaVersion < 2 || snapshot.pendingMealIds.isNotEmpty()) return true
    val fetched = Instant.ofEpochMilli(snapshot.fetchedAtEpochMillis).atZone(PennStateZone)
    val now = Instant.ofEpochMilli(nowMillis).atZone(PennStateZone)
    if (fetched > now) return true
    val today = now.toLocalDate()
    if (snapshot.localDate < today) return false
    if (snapshot.localDate > today) return fetched.toLocalDate() < today
    if (fetched.toLocalDate() != today) return true
    val age = nowMillis - snapshot.fetchedAtEpochMillis
    // Penn State can publish the remaining meals later. Sparse/empty results need an earlier retry.
    if ((snapshot.meals.size <= 1 || snapshot.meals.any { it.sections.isEmpty() }) && age >= 15 * 60_000L) return true
    if (hours == null) return age >= 4 * 60 * 60_000L
    return hours.intervals.any { interval ->
        val boundary = today.atStartOfDay().plusMinutes(interval.startMinutes.toLong()).atZone(PennStateZone)
        fetched < boundary && boundary <= now
    }
}

/** Keep usable saved items while accepting the provider's complete picker and newly loaded meals. */
internal fun mergeMenuProgress(saved: MenuDaySnapshot?, progress: MenuDaySnapshot): MenuDaySnapshot {
    if (saved == null || saved.hallId != progress.hallId || saved.date != progress.date) return progress
    val savedMeals = saved.meals.filter { it.sections.isNotEmpty() }.associateBy { it.id }
    return progress.copy(
        meals = progress.meals.map { meal ->
            if (meal.id in progress.pendingMealIds) savedMeals[meal.id] ?: meal else meal
        },
        pendingMealIds = progress.pendingMealIds - savedMeals.keys,
    )
}
