package com.ryannair05.meetandeat.dining

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.conflate
import androidx.core.content.edit
import com.squareup.moshi.Json
import com.squareup.moshi.Moshi
import com.squareup.moshi.Types
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

class DiningRepository(
    context: Context,
    private val source: PennStateDiningSource = PennStateDiningSource(),
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val moshi = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build()
    private val menuAdapter = moshi.adapter(MenuDaySnapshot::class.java).indent("  ")
    private val detailAdapter = moshi.adapter(MenuItemDetail::class.java).indent("  ")
    private val menusDir = File(appContext.cacheDir, "dining/menus")
    private val detailsDir = File(appContext.cacheDir, "dining/item-details")
    private val memory = object : LinkedHashMap<String, MenuDaySnapshot>(16, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, MenuDaySnapshot>?) = size > 10
    }
    private val detailMemory = object : LinkedHashMap<String, MenuItemDetail>(32, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, MenuItemDetail>?) = size > 24
    }
    private val cacheMutex = Mutex()
    private val menuRequests = MenuRequests(scope)
    private val detailInFlight = mutableMapOf<String, kotlinx.coroutines.Deferred<MenuItemDetail>>()
    private val hours = PennStateHoursStore(File(appContext.cacheDir, "dining/hours/penn-state-v2.json"), moshi, nowMillis)

    suspend fun cachedMenu(hall: PSUDiningHall, date: LocalDate): MenuDaySnapshot? =
        withContext(Dispatchers.IO) { cacheMutex.withLock { loadMenuCache(menuKey(hall, date)) } }

    suspend fun menu(
        hall: PSUDiningHall,
        date: LocalDate,
        forceRefresh: Boolean = false,
        preferredMealId: String? = null,
        onPartial: suspend (MenuDaySnapshot) -> Unit = {},
    ): MenuDaySnapshot {
        val key = menuKey(hall, date)
        val cached = withContext(Dispatchers.IO) { cacheMutex.withLock { loadMenuCache(key) } }
        if (cached != null) onPartial(cached)
        if (!forceRefresh && cached != null && !isStale(cached, hours.hours(hall, date, cacheOnly = true))) return cached

        val cachedHours = hours.hours(hall, date, cacheOnly = true)
        return try {
            menuRequests.load(key, onPartial) { progress ->
                source.loadMenu(hall, date, preferredMealId, progress, preferredMeal = { options ->
                    val choices = MenuDaySnapshot(hallId = hall.id, date = date.toString(),
                        fetchedAtEpochMillis = nowMillis(), meals = options)
                    resolveMealSelection(choices, date, cachedHours, preferredMealId, false)
                }).also { storeMenu(key, it) }
            }
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            cached?.copy(isStaleFallback = true) ?: throw error
        }
    }

    suspend fun itemDetail(
        item: DiningMenuItem,
        hall: PSUDiningHall,
        date: LocalDate,
        forceRefresh: Boolean = false,
    ): MenuItemDetail {
        val key = normalizeDiningText(item.name, "-")
        val cached = withContext(Dispatchers.IO) { cacheMutex.withLock { loadDetailCache(key) } }
        if (!forceRefresh && cached != null && nowMillis() - cached.fetchedAtEpochMillis < DETAIL_LIFETIME) return cached

        var sourceWasRefreshed = false
        var candidate = item
        if (!source.hasSessionFor(item.detailUrl)) {
            try {
                candidate = refreshDetailSource(item, hall, date) ?: item
                sourceWasRefreshed = true
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                return cached ?: throw error
            }
        }
        return try {
            fetchItemDetail(candidate, key)
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (!sourceWasRefreshed && error.shouldRefreshDetailSource()) {
                val refreshed = refreshDetailSource(item, hall, date)
                if (refreshed != null) {
                    return try {
                        fetchItemDetail(refreshed, key)
                    } catch (retryError: Throwable) {
                        if (retryError is CancellationException) throw retryError
                        cached ?: throw retryError
                    }
                }
            }
            cached ?: throw error
        }
    }

    private suspend fun fetchItemDetail(item: DiningMenuItem, key: String): MenuItemDetail {
        val task = cacheMutex.withLock {
            detailInFlight.entries.removeAll { it.value.isCompleted }
            detailInFlight[key] ?: scope.async { source.loadItemDetail(item).also { storeDetail(key, it) } }
                .also { detailInFlight[key] = it }
        }
        return try {
            task.await()
        } finally {
            if (task.isCompleted) withContext(kotlinx.coroutines.NonCancellable) {
                cacheMutex.withLock { if (detailInFlight[key] === task) detailInFlight.remove(key) }
            }
        }
    }

    private suspend fun refreshDetailSource(
        item: DiningMenuItem,
        hall: PSUDiningHall,
        date: LocalDate,
    ): DiningMenuItem? {
        val snapshot = menu(hall, date, forceRefresh = true)
        return refreshedDetailItem(snapshot, item)
    }

    suspend fun hoursForDay(date: LocalDate, cacheOnly: Boolean = false, forceRefresh: Boolean = false): DiningHoursSnapshot =
        hours.snapshot(date, cacheOnly, forceRefresh)

    suspend fun menuSearch(
        date: LocalDate,
        query: String,
        filter: DietaryFilter,
        onCoverage: suspend (indexed: Int, total: Int) -> Unit = { _, _ -> },
    ): List<DiningSearchResult> = coroutineScope {
        val normalizedQuery = normalizeDiningText(query)
        if (normalizedQuery.length < 3) return@coroutineScope emptyList()
        val completed = java.util.concurrent.atomic.AtomicInteger(0)
        val snapshots = PSUDiningHall.entries.map { hall ->
            async {
                runCatching { hall to menu(hall, date) }.getOrNull().also {
                    onCoverage(completed.incrementAndGet(), PSUDiningHall.entries.size)
                }
            }
        }.awaitAll().filterNotNull()

        data class Hit(val item: DiningMenuItem, val appearance: DiningSearchAppearance)
        val hits = snapshots.flatMap { (hall, snapshot) ->
            snapshot.meals.flatMap { meal ->
                meal.sections.flatMap { section ->
                    section.items.filter { item ->
                        normalizeDiningText(item.name).contains(normalizedQuery) && filter.matches(item)
                    }.map { item ->
                        Hit(item, DiningSearchAppearance(hall, date, listOf(meal.name), listOf(section.name)))
                    }
                }
            }
        }
        hits.groupBy { normalizeDiningText(it.item.name) }.values.map { group ->
            DiningSearchResult(
                item = group.first().item,
                appearances = group.groupBy { it.appearance.hall }.map { (hall, hallHits) ->
                    DiningSearchAppearance(
                        hall,
                        date,
                        hallHits.flatMap { it.appearance.mealNames }.distinct(),
                        hallHits.flatMap { it.appearance.sectionNames }.distinct(),
                    )
                },
            )
        }.sortedWith(compareBy<DiningSearchResult> {
            !normalizeDiningText(it.item.name).startsWith(normalizedQuery)
        }.thenBy { it.item.name })
    }

    suspend fun availability(item: DiningMenuItem, date: LocalDate): List<DiningSearchAppearance> = coroutineScope {
        val canonical = normalizeDiningText(item.name)
        PSUDiningHall.entries.map { hall ->
            async {
                val snapshot = runCatching { menu(hall, date) }.getOrNull() ?: return@async null
                val matching = snapshot.meals.flatMap { meal ->
                    meal.sections.flatMap { section ->
                        section.items.filter { normalizeDiningText(it.name) == canonical }
                            .map { meal.name to section.name }
                    }
                }
                if (matching.isEmpty()) null else DiningSearchAppearance(
                    hall, date, matching.map { it.first }.distinct(), matching.map { it.second }.distinct()
                )
            }
        }.awaitAll().filterNotNull()
    }

    suspend fun prune() = withContext(Dispatchers.IO) {
        val keepAfter = LocalDate.now(PennStateZone).minusDays(2)
        menusDir.listFiles()?.filter { file ->
            runCatching { LocalDate.parse(file.name.substringAfterLast('_').removeSuffix(".json")) < keepAfter }.getOrDefault(false)
        }?.forEach(File::delete)
    }

    internal fun isStale(snapshot: MenuDaySnapshot, dayHours: DayHours?): Boolean =
        menuIsStale(snapshot, dayHours, nowMillis())

    private fun menuKey(hall: PSUDiningHall, date: LocalDate) = "${hall.id}_${date}"

    private fun loadMenuCache(key: String): MenuDaySnapshot? {
        memory[key]?.let { return it }
        val file = File(menusDir, "$key.json")
        val value = runCatching { menuAdapter.fromJson(file.readText()) }.getOrNull()
        if (value == null) file.delete() else memory[key] = value
        return value
    }

    private suspend fun storeMenu(key: String, snapshot: MenuDaySnapshot) = cacheMutex.withLock {
        check(snapshot.pendingMealIds.isEmpty()) { "Cannot persist an incomplete menu" }
        memory[key] = snapshot
        runCatching { atomicWrite(File(menusDir, "$key.json"), menuAdapter.toJson(snapshot)) }
    }

    private fun loadDetailCache(key: String): MenuItemDetail? {
        detailMemory[key]?.let { return it }
        val file = File(detailsDir, "$key.json")
        val value = runCatching { detailAdapter.fromJson(file.readText()) }.getOrNull()
        if (value == null) file.delete() else detailMemory[key] = value
        return value
    }

    private suspend fun storeDetail(key: String, detail: MenuItemDetail) = cacheMutex.withLock {
        detailMemory[key] = detail
        runCatching { atomicWrite(File(detailsDir, "$key.json"), detailAdapter.toJson(detail)) }
    }

    private fun atomicWrite(file: File, text: String) = writeCacheAtomically(file, text.toByteArray())

    companion object { private const val DETAIL_LIFETIME = 30L * 24 * 60 * 60 * 1000 }
}

class DietaryFilterStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("dining_preferences", Context.MODE_PRIVATE)
    fun read(): DietaryFilter = DietaryFilter(
        preferences.getStringSet("dietary_requirements", emptySet()).orEmpty()
            .mapNotNull { raw -> DietaryRequirement.entries.firstOrNull { it.name == raw } }.toSet()
    )
    val changes = callbackFlow {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "dietary_requirements" || key == null) trySend(read())
        }
        preferences.registerOnSharedPreferenceChangeListener(listener)
        trySend(read())
        awaitClose { preferences.unregisterOnSharedPreferenceChangeListener(listener) }
    }.conflate()

    fun write(value: DietaryFilter) = preferences.edit {
        putStringSet("dietary_requirements", value.required.map { it.name }.toSet())
    }
}

object DiningGraph {
    @Volatile private var repository: DiningRepository? = null
    fun repository(context: Context): DiningRepository = repository ?: synchronized(this) {
        repository ?: DiningRepository(context).also { repository = it }
    }
}

internal object PennStateHoursParser {
    private data class RawRecord(
        @Json(name = "dining_location") val location: String?,
        @Json(name = "dining_area") val area: String? = null,
        val hours: List<RawHour>?,
    )
    private data class RawHour(
        val day: String?,
        val start: String?,
        val end: String?,
        val timezone: String?,
        val comment: String?,
    )

    fun parse(json: String, moshi: Moshi = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build()): Map<String, Map<String, DayHours>> {
        val adapter = moshi.adapter<List<RawRecord>>(
            Types.newParameterizedType(List::class.java, RawRecord::class.java)
        )
        val records = adapter.fromJson(json).orEmpty()
        val areas = mapOf("South Food District" to "south", "East Food District" to "east",
            "West Food District" to "west", "North Food District" to "north", "Pollock Dining Commons" to "pollock")
        val groups = PSUDiningHall.entries.associate { hall ->
            hall.id to records.filter { it.location == hall.hoursSourceName }
        }.toMutableMap()
        records.filter { it.location != null && it.area in areas }.groupBy { record ->
            val decodedName = org.jsoup.parser.Parser.unescapeEntities(record.location!!, false)
            "station:${areas[record.area]}:${normalizeDiningText(decodedName)}"
        }.forEach { (key, entries) -> groups[key] = entries }
        val parsed = groups.mapNotNull { (key, matchingRecords) ->
            if (matchingRecords.isEmpty()) return@mapNotNull null
            val matching = matchingRecords.flatMap { it.hours.orEmpty() }
            key to DayOfWeek.entries.associate { weekday ->
                val source = matching.filter { raw ->
                    raw.day?.trim()?.equals(weekday.getDisplayName(TextStyle.FULL, Locale.US), true) == true &&
                        (raw.timezone == null || raw.timezone == PennStateZone.id)
                }
                val intervals = source.mapNotNull { raw ->
                    val start = raw.start?.let(::minutes) ?: return@mapNotNull null
                    var end = raw.end?.let(::minutes) ?: return@mapNotNull null
                    if (end == 0 && start > 0) end = 1440
                    if (end <= start) return@mapNotNull null
                    DiningHoursInterval(start, end, raw.comment?.trim()?.takeIf(String::isNotBlank))
                }.distinct().sortedBy { it.startMinutes }
                weekday.name to DayHours(
                    intervals,
                    intervals.isEmpty() && source.any { it.comment?.contains("closed", true) == true },
                )
            }
        }.toMap()
        require(hasSupportedHours(parsed)) { "The hours response contained no supported hours or closures" }
        return parsed
    }

    private fun minutes(value: String): Int? = runCatching {
        LocalTime.parse(value.take(5), DateTimeFormatter.ofPattern("HH:mm")).let { it.hour * 60 + it.minute }
    }.getOrNull()
}

fun DayHours?.statusText(now: LocalTime = LocalTime.now(PennStateZone)): String {
    if (this == null) return "Hours unavailable"
    if (explicitlyClosed) return "Closed"
    if (intervals.isEmpty()) return "Hours unavailable"
    val minute = now.hour * 60 + now.minute
    val current = intervals.firstOrNull { minute in it.startMinutes until it.endMinutes }
    if (current != null) return "Open · until ${formatMinutes(current.endMinutes)}"
    val next = intervals.firstOrNull { it.startMinutes > minute }
    return next?.let { "Closed · opens ${formatMinutes(it.startMinutes)}" } ?: "Closed for today"
}

fun formatMinutes(value: Int): String {
    val time = if (value == 1440) LocalTime.MIDNIGHT else LocalTime.of(value / 60, value % 60)
    return time.format(DateTimeFormatter.ofPattern("h:mm a", Locale.US))
}

private fun Throwable.shouldRefreshDetailSource(): Boolean = when (this) {
    is DiningSourceException.NoPublishedMenu,
    is DiningSourceException.Http,
    is DiningSourceException.Markup -> true
    else -> false
}

internal fun refreshedDetailItem(
    snapshot: MenuDaySnapshot,
    original: DiningMenuItem,
): DiningMenuItem? {
    val published = snapshot.meals.flatMap { meal ->
        meal.sections.flatMap(DiningMenuSection::items)
    }.filter { it.detailUrl != null }
    return published.firstOrNull { it.id == original.id }
        ?: published.firstOrNull { normalizeDiningText(it.name) == normalizeDiningText(original.name) }
}
