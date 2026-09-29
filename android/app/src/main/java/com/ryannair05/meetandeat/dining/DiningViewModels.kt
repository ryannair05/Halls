package com.ryannair05.meetandeat.dining

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.async
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.LocalDate

data class DiningListUiState(
    val hours: Map<PSUDiningHall, DayHours?> = emptyMap(),
    val hoursLoading: Boolean = true,
    val filter: DietaryFilter = DietaryFilter(),
    val searchQuery: String = "",
    val searchResults: List<DiningSearchResult> = emptyList(),
    val searchedHallCount: Int = 0,
    val isRefreshing: Boolean = false,
    val isSearching: Boolean = false,
    val error: String? = null,
)

class DiningListViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = DiningGraph.repository(application)
    private val filterStore = DietaryFilterStore(application)
    private val _state = MutableStateFlow(DiningListUiState(filter = filterStore.read()))
    val state: StateFlow<DiningListUiState> = _state.asStateFlow()
    private var searchJob: Job? = null
    private var refreshJob: Job? = null

    init {
        viewModelScope.launch {
            filterStore.changes.collect { filter ->
                if (filter != _state.value.filter) {
                    _state.update { it.copy(filter = filter) }
                    if (_state.value.searchQuery.trim().length >= 3) runSearch()
                }
            }
        }
        refreshHours(false)
    }

    fun refresh() = refreshHours(true)

    private fun refreshHours(force: Boolean) {
        refreshJob?.cancel()
        refreshJob = viewModelScope.launch {
            _state.update { it.copy(isRefreshing = force, hoursLoading = true, error = null) }
            val date = LocalDate.now(PennStateZone)
            val cached = repository.hoursForDay(date, cacheOnly = true)
            _state.update { it.copy(hours = cached.halls) }
            val hours = repository.hoursForDay(date, forceRefresh = force)
            _state.update { it.copy(hours = hours.halls, hoursLoading = false, isRefreshing = false) }
            if (_state.value.searchQuery.length >= 3) runSearch()
            repository.prune()
        }
    }

    fun setSearchQuery(value: String) {
        _state.update { it.copy(searchQuery = value) }
        searchJob?.cancel()
        if (value.trim().length < 3) {
            _state.update { it.copy(searchResults = emptyList(), isSearching = false, searchedHallCount = 0) }
            return
        }
        searchJob = viewModelScope.launch { delay(180); runSearch() }
    }

    fun toggleFilter(requirement: DietaryRequirement) {
        val current = _state.value.filter.required.toMutableSet()
        if (!current.add(requirement)) current.remove(requirement)
        val filter = DietaryFilter(current)
        filterStore.write(filter)
    }

    fun clearFilters() {
        filterStore.write(DietaryFilter())
    }

    private fun runSearch() {
        val query = _state.value.searchQuery.trim()
        if (query.length < 3) return
        searchJob?.cancel()
        searchJob = viewModelScope.launch {
            _state.update { it.copy(isSearching = true, searchedHallCount = 0, error = null) }
            runCatching {
                repository.menuSearch(LocalDate.now(PennStateZone), query, _state.value.filter) { indexed, _ ->
                    _state.update { it.copy(searchedHallCount = indexed) }
                }
            }.onSuccess { results ->
                _state.update { it.copy(searchResults = results, isSearching = false) }
            }.onFailure { error ->
                if (error is kotlinx.coroutines.CancellationException) throw error
                _state.update { it.copy(isSearching = false, error = error.userMessage()) }
            }
        }
    }
}

data class DiningMenuUiState(
    val hall: PSUDiningHall,
    val date: LocalDate,
    val snapshotState: LoadState<MenuDaySnapshot> = LoadState.Idle,
    val isRefreshing: Boolean = false,
    val selectedMealId: String? = null,
    val searchQuery: String = "",
    val filter: DietaryFilter = DietaryFilter(),
    val dayHours: DayHours? = null,
    val hoursLoading: Boolean = true,
    val isMenuLoading: Boolean = true,
    val stationHours: Map<String, DayHours> = emptyMap(),
) {
    val snapshot: MenuDaySnapshot?
        get() = when (val state = snapshotState) {
            is LoadState.Ready -> state.value
            is LoadState.Loading -> state.cached
            is LoadState.Error -> state.cached
            else -> null
        }
    val selectedMeal: DiningMealPeriod?
        get() = snapshot?.meals?.firstOrNull { it.id == selectedMealId }
    val visibleSections: List<DiningMenuSection>
        get() {
            val query = normalizeDiningText(searchQuery)
            return selectedMeal?.sections.orEmpty().mapNotNull { section ->
                val items = section.items.filter { item ->
                    (query.isBlank() || normalizeDiningText(item.name).contains(query)) && filter.matches(item)
                }
                if (items.isEmpty()) null else section.copy(items = items)
            }
        }
}

class DiningMenuViewModel(
    application: Application,
    hall: PSUDiningHall,
    initialDate: LocalDate = LocalDate.now(PennStateZone),
    initialMealId: String? = null,
    initialSearchQuery: String = "",
) : AndroidViewModel(application) {
    private val repository = DiningGraph.repository(application)
    private val filterStore = DietaryFilterStore(application)
    private val _state = MutableStateFlow(DiningMenuUiState(hall, initialDate, filter = filterStore.read(), selectedMealId = initialMealId, searchQuery = initialSearchQuery))
    val state: StateFlow<DiningMenuUiState> = _state.asStateFlow()
    private var loadJob: Job? = null
    private var explicitlySelectedMealId: String? = initialMealId
    private var loadGeneration = 0L

    init {
        viewModelScope.launch {
            filterStore.changes.collect { filter -> _state.update { it.copy(filter = filter) } }
        }
        load(false)
    }

    fun selectDate(date: LocalDate) {
        if (date == _state.value.date) return
        explicitlySelectedMealId = null
        _state.update { it.copy(date = date, selectedMealId = null, dayHours = null, stationHours = emptyMap(), snapshotState = LoadState.Loading()) }
        load(false)
    }

    fun selectMeal(id: String) {
        explicitlySelectedMealId = id
        _state.update { it.copy(selectedMealId = id) }
    }
    fun setSearchQuery(value: String) = _state.update { it.copy(searchQuery = value) }

    fun toggleFilter(requirement: DietaryRequirement) {
        val required = _state.value.filter.required.toMutableSet()
        if (!required.add(requirement)) required.remove(requirement)
        val filter = DietaryFilter(required)
        filterStore.write(filter)
        _state.update { it.copy(filter = filter) }
    }

    fun clearFilters() {
        filterStore.write(DietaryFilter())
        _state.update { it.copy(filter = DietaryFilter()) }
    }

    fun refresh() = load(true)

    fun revalidate() {
        val state = _state.value
        val snapshot = state.snapshot ?: return
        if (loadJob?.isActive != true && repository.isStale(snapshot, state.dayHours)) load(false)
    }

    fun shareText(): String? {
        val state = _state.value
        val meal = state.selectedMeal ?: return null
        return buildString {
            appendLine("${state.hall.displayName} Dining · ${meal.name} · ${state.date}")
            meal.sections.forEach { section ->
                appendLine()
                appendLine(section.name)
                section.items.forEach { appendLine("• ${it.name}") }
            }
            appendLine()
            append("Shared from Halls")
        }
    }

    private fun load(force: Boolean) {
        loadJob?.cancel()
        val generation = ++loadGeneration
        loadJob = viewModelScope.launch {
            val hall = _state.value.hall
            val date = _state.value.date
            fun current() = generation == loadGeneration && _state.value.date == date
            val previous = _state.value.snapshot?.takeIf { it.date == date.toString() }
            _state.update { it.copy(isRefreshing = force, isMenuLoading = true, hoursLoading = true,
                snapshotState = LoadState.Loading(previous)) }
            val cached = repository.cachedMenu(hall, date)
            ensureActive()
            if (!current()) return@launch
            // Cache-only reads cannot wait behind an hours network request.
            val cachedHours = repository.hoursForDay(date, cacheOnly = true)
            _state.update { it.copy(dayHours = cachedHours.halls[hall], stationHours = cachedHours.stations[hall].orEmpty()) }
            if (cached != null) applySnapshot(cached, refreshing = true)
            launch {
                val hours = repository.hoursForDay(date, forceRefresh = force)
                ensureActive()
                if (current()) _state.update { old ->
                    old.copy(dayHours = hours.halls[hall], stationHours = hours.stations[hall].orEmpty(),
                        hoursLoading = false,
                        selectedMealId = old.snapshot?.let {
                            resolveMealSelection(it, date, hours.halls[hall], explicitlySelectedMealId, false)
                        } ?: old.selectedMealId)
                }
            }
            try {
                val snapshot = repository.menu(hall, date, force, explicitlySelectedMealId) { partial ->
                    ensureActive()
                    if (current()) applySnapshot(mergeMenuProgress(cached, partial), refreshing = true)
                }
                ensureActive()
                if (!current()) return@launch
                if (!snapshot.hasPublishedItems) {
                    _state.update { it.copy(snapshotState = LoadState.Empty("This dining hall hasn't published items for this date.")) }
                } else {
                    val displayed = if (snapshot.isStaleFallback) _state.value.snapshot?.takeIf { it.hasPublishedItems } ?: snapshot else snapshot
                    applySnapshot(displayed, refreshing = false)
                    if (snapshot.isStaleFallback) {
                        val updated = java.time.Instant.ofEpochMilli(snapshot.fetchedAtEpochMillis)
                            .atZone(PennStateZone).format(java.time.format.DateTimeFormatter.ofPattern("MMM d, h:mm a"))
                        val message = if (displayed.pendingMealIds.isNotEmpty()) "Some meals couldn't refresh. Showing available items."
                            else "Showing saved menu · Updated $updated"
                        _state.update { it.copy(snapshotState = LoadState.Error(message, displayed)) }
                    }
                }
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                if (current()) _state.update {
                    val retained = it.snapshot ?: cached
                    it.copy(snapshotState = LoadState.Error(error.userMessage(), retained))
                }
            } finally {
                if (current()) _state.update { it.copy(isRefreshing = false, isMenuLoading = false) }
            }
        }
    }

    private fun applySnapshot(snapshot: MenuDaySnapshot, refreshing: Boolean) {
        if (!refreshing && explicitlySelectedMealId != null && snapshot.meals.none { it.id == explicitlySelectedMealId }) {
            explicitlySelectedMealId = null
        }
        if (snapshot.hallId != _state.value.hall.id || snapshot.date != _state.value.date.toString()) return
        _state.update { old ->
            val selected = resolveMealSelection(
                snapshot = snapshot,
                date = old.date,
                hours = old.dayHours,
                explicitMealId = explicitlySelectedMealId,
                refreshing = false,
            )
            old.copy(snapshotState = LoadState.Ready(snapshot, refreshing), selectedMealId = selected)
        }
    }
}

internal fun resolveMealSelection(
    snapshot: MenuDaySnapshot,
    date: LocalDate,
    hours: DayHours?,
    explicitMealId: String?,
    refreshing: Boolean,
    today: LocalDate = LocalDate.now(PennStateZone),
    minute: Int = java.time.LocalTime.now(PennStateZone).let { it.hour * 60 + it.minute },
): String? {
    if (explicitMealId != null && (refreshing || snapshot.meals.any { it.id == explicitMealId })) {
        return explicitMealId
    }
    automaticMealForTime(snapshot, date, hours, today, minute)?.let { return it.id }
    if (refreshing) return null
    val automaticChoices = snapshot.meals.filterNot(DiningMealPeriod::isLateNight)
    return if (date == today) automaticChoices.lastOrNull()?.id else automaticChoices.firstOrNull()?.id
}

internal fun automaticMealForTime(
    snapshot: MenuDaySnapshot,
    date: LocalDate,
    hours: DayHours?,
    today: LocalDate = LocalDate.now(PennStateZone),
    minute: Int = java.time.LocalTime.now(PennStateZone).let { it.hour * 60 + it.minute },
): DiningMealPeriod? {
    if (date != today) return snapshot.meals.firstOrNull { !it.isLateNight() }
    val intervals = hours?.intervals.orEmpty()
    val active = intervals.firstOrNull { minute in it.startMinutes until it.endMinutes }
    val upcoming = intervals.filter { minute < it.startMinutes }.minByOrNull(DiningHoursInterval::startMinutes)
    val target = (active ?: upcoming)?.label ?: return null
    return snapshot.meals.firstOrNull { meal ->
        !meal.isLateNight() && servicePeriodLabelsMatch(meal.name, target)
    }
}

private fun DiningMealPeriod.isLateNight(): Boolean = normalizedServicePeriod(name) == "late-night"

internal fun servicePeriodLabelsMatch(menuLabel: String, hoursLabel: String): Boolean {
    val menu = normalizedServicePeriod(menuLabel)
    val hours = normalizedServicePeriod(hoursLabel)
    if (menu == hours) return true
    return (menu == "lunch" && hours == "brunch") || (menu == "brunch" && hours == "lunch")
}

private fun normalizedServicePeriod(label: String): String = when (normalizeDiningText(label, "-")) {
    "breakfast", "breakfast-service", "continental-breakfast", "morning" -> "breakfast"
    "brunch", "brunch-service" -> "brunch"
    "lunch", "lunch-service", "midday", "midday-service" -> "lunch"
    "dinner", "dinner-service", "supper", "evening-service" -> "dinner"
    "late-night", "late-night-service", "late-nite", "latenight" -> "late-night"
    "all-day", "all-day-service", "continuous", "daily" -> "all-day"
    else -> normalizeDiningText(label, "-")
}

data class MenuItemDetailUiState(
    val item: DiningMenuItem,
    val date: LocalDate,
    val detail: LoadState<MenuItemDetail> = LoadState.Idle,
    val availability: List<DiningSearchAppearance> = emptyList(),
    val failureKind: MenuItemDetailFailureKind? = null,
)

enum class MenuItemDetailFailureKind { MARKUP, TRANSPORT }

class MenuItemDetailViewModel(
    application: Application,
    item: DiningMenuItem,
    private val hall: PSUDiningHall,
    date: LocalDate,
    private val includeAvailability: Boolean,
) : AndroidViewModel(application) {
    private val repository = DiningGraph.repository(application)
    private val _state = MutableStateFlow(MenuItemDetailUiState(item, date))
    val state = _state.asStateFlow()

    init { load(false) }
    fun refresh() = load(true)

    private fun load(force: Boolean) = viewModelScope.launch {
        _state.update { it.copy(detail = LoadState.Loading(), failureKind = null) }
        if (includeAvailability) launch {
            val availability = runCatching { repository.availability(_state.value.item, _state.value.date) }.getOrDefault(emptyList())
            _state.update { it.copy(availability = availability) }
        }
        runCatching { repository.itemDetail(_state.value.item, hall, _state.value.date, force) }
            .onSuccess { detail -> _state.update { it.copy(detail = LoadState.Ready(detail), failureKind = null) } }
            .onFailure { error ->
                if (error is DiningSourceException.NoPublishedMenu) {
                    _state.update {
                        it.copy(
                            detail = LoadState.Empty("Penn State does not publish ingredients or nutrition for this item."),
                            failureKind = null,
                        )
                    }
                } else {
                    _state.update {
                        it.copy(
                            detail = LoadState.Error(error.userMessage()),
                            failureKind = if (error is DiningSourceException.Markup) {
                                MenuItemDetailFailureKind.MARKUP
                            } else {
                                MenuItemDetailFailureKind.TRANSPORT
                            },
                        )
                    }
                }
            }
    }
}

@Suppress("UNCHECKED_CAST")
fun <VM : ViewModel> simpleViewModelFactory(create: () -> VM): ViewModelProvider.Factory =
    object : ViewModelProvider.Factory {
        override fun <T : ViewModel> create(modelClass: Class<T>): T = create() as T
    }

private fun Throwable.userMessage(): String = when (this) {
    is DiningSourceException -> message ?: "Dining data is unavailable."
    else -> "Check your connection and try again."
}
