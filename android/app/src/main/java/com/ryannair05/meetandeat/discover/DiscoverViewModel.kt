package com.ryannair05.meetandeat.discover

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

internal data class DiscoverUiState(
    val snapshot: DiscoverSnapshot = DiscoverSnapshot(), val saved: DiscoverSaved = DiscoverSaved(),
    val filters: DiscoverFilters = DiscoverFilters(), val loading: Boolean = false, val loaded: Boolean = false,
    val issues: List<String> = emptyList(), val saveError: String? = null, val canSave: Boolean = false,
    val now: Long = System.currentTimeMillis(),
    val saving: Boolean = false,
) {
    val supportsPerks get() = snapshot.eventSource == EventSource.JSON
    val clubCategories get() = snapshot.organizations.flatMap { it.categories }.distinct().sorted()
    val eventCategories get() = snapshot.events.flatMap { it.categories }.distinct().sorted()
    fun club(id: String) = snapshot.organizations.firstOrNull { it.id == id } ?: saved.organizations[id]
    fun event(id: String) = snapshot.events.firstOrNull { it.id == id } ?: saved.events[id]
    fun clubEvents(id: String) = snapshot.events.filter { !it.cancelled && it.upcoming(now) && id in it.organizationIds }
    val savedClubs get() = saved.organizations.values.sortedBy { DiscoverSource.normalized(it.name) }
    val savedUpcoming get() = saved.events.values.filter { it.upcoming(now) }.sortedBy { it.start }
    val savedPast get() = saved.events.values.filterNot { it.upcoming(now) }.sortedByDescending { it.start }
}
internal fun matchesEvent(event: CampusEvent, filters: DiscoverFilters, saved: DiscoverSaved, now: Long, home: Boolean, searchText: String): Boolean {
    if (event.cancelled || filters.freeFood && "Free Food" !in event.benefits) return false
    if (!(if (home) filters.homeDate else filters.date).includes(event, now)) return false
    return (filters.eventCategory.isEmpty() || filters.eventCategory in event.categories) &&
        (!filters.onlineOnly || event.online) && (!filters.savedClubsOnly || event.organizationIds.any { it in saved.organizations }) &&
        (home || DiscoverSource.normalized(filters.eventQuery) in searchText)
}
internal class DiscoverViewModel(application: Application, private val retained: SavedStateHandle) : AndroidViewModel(application) {
    private val repository = DiscoverRepository(DiscoverFileStore(File(application.filesDir, "discover")))
    private val filterAdapter = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build().adapter(DiscoverFilters::class.java)
    private val mutable = MutableStateFlow(DiscoverUiState(filters = runCatching {
        retained.get<String>("filters")?.let(filterAdapter::fromJson)
    }.getOrNull() ?: DiscoverFilters()))
    val state = mutable.asStateFlow()
    private val saving = Mutex()
    private var initialized = false
    private var clubIndex = emptyMap<String, String>()
    private var eventIndex = emptyMap<String, String>()
    init { refresh() }
    fun refresh(force: Boolean = false) {
        if (mutable.value.loading) return
        mutable.update { it.copy(loading = true) }
        viewModelScope.launch {
            try {
                if (!initialized) {
                    val cached = repository.cached()
                    mutable.update { it.copy(snapshot = cached) }; index(cached)
                    initialized = true
                }
                if (!mutable.value.loaded || !mutable.value.canSave) {
                    attempt { repository.saved() }.fold(onSuccess = { saved -> mutable.update { it.copy(saved = saved, canSave = true, saveError = null) } },
                        onFailure = { mutable.update { it.copy(canSave = false, saveError = "Saved items could not be opened. Try again to recover them.") } })
                }
                val result = repository.refresh(force)
                index(result.snapshot)
                mutable.update { it.copy(snapshot = result.snapshot, issues = result.issues, now = System.currentTimeMillis(),
                    filters = if (result.snapshot.eventSource != EventSource.JSON) it.filters.copy(freeFood = false) else it.filters) }
                saving.withLock {
                    if (mutable.value.canSave) persist(mutable.value.saved.merge(result.snapshot))
                }
            } catch (error: kotlinx.coroutines.CancellationException) { throw error }
            catch (error: Exception) {
                mutable.update { it.copy(issues = listOf("Couldn’t refresh Discover. Your available content has been kept; try again.")) }
            } finally { mutable.update { it.copy(loading = false, loaded = true) } }
        }
    }
    private fun index(snapshot: DiscoverSnapshot) {
        clubIndex = snapshot.organizations.associate { it.id to DiscoverSource.normalized("${it.name} ${it.summary} ${it.categories.joinToString(" ")}") }
        eventIndex = snapshot.events.associate { it.id to DiscoverSource.normalized("${it.title} ${it.hostNames.joinToString(" ")} ${it.description}") }
    }
    fun tick() { mutable.update { it.copy(now = System.currentTimeMillis()) } }
    fun filter(change: (DiscoverFilters) -> DiscoverFilters) {
        mutable.update { it.copy(filters = change(it.filters)) }
        retained["filters"] = filterAdapter.toJson(mutable.value.filters)
    }
    fun resetEvents() = filter { it.resetEventFilters(home = false) }
    fun prepareEvents() = filter { it.copy(date = DiscoverDate.WEEK, eventQuery = "", eventCategory = "", onlineOnly = false, savedClubsOnly = false) }
    fun clubs(s: DiscoverUiState): List<CampusOrganization> {
        val query = DiscoverSource.normalized(s.filters.clubQuery)
        return s.snapshot.organizations.filter { (s.filters.clubCategory.isEmpty() || s.filters.clubCategory in it.categories) && query in clubIndex[it.id].orEmpty() }
    }
    fun events(s: DiscoverUiState, home: Boolean): List<CampusEvent> = s.snapshot.events.filter {
        matchesEvent(it, s.filters, s.saved, s.now, home, eventIndex[it.id].orEmpty())
    }
    fun toggle(club: CampusOrganization) = changeSaved { saved -> saved.copy(organizations = saved.organizations.toMutableMap().apply { if (remove(club.id) == null) put(club.id, club) }) }
    fun toggle(event: CampusEvent) = changeSaved { saved -> saved.copy(events = saved.events.toMutableMap().apply { if (remove(event.id) == null) put(event.id, event) }) }
    private fun changeSaved(change: (DiscoverSaved) -> DiscoverSaved) {
        if (!mutable.value.canSave || mutable.value.saving) return
        mutable.update { it.copy(saving = true) }
        viewModelScope.launch {
            try { saving.withLock { persist(change(mutable.value.saved)) } }
            finally { mutable.update { it.copy(saving = false) } }
        }
    }
    private suspend fun persist(next: DiscoverSaved) {
        attempt { repository.save(next) }.fold(
            onSuccess = { mutable.update { it.copy(saved = next, saveError = null) } },
            onFailure = { mutable.update { it.copy(saveError = "Your changes could not be saved on this device. Please try again.") } },
        )
    }
}
