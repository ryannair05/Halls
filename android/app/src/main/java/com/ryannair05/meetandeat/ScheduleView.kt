/*
 * ScheduleScreen.kt
 *
 * Author: Ryan Nair – 8 Jun 2025
 */

package com.ryannair05.meetandeat

import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode

import android.content.Intent
import androidx.compose.animation.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Today
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.core.net.toUri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import java.util.UUID
import kotlin.time.Duration.Companion.milliseconds

/* ─────────────────────────────── Data Models ────────────────────────────── */

@Immutable
data class ActivitySchedule(
    val id: String = UUID.randomUUID().toString(),
    val activity: String,
    val tables: List<ScheduleTable>
)

@Immutable
data class ScheduleTable(
    val id: String = UUID.randomUUID().toString(),
    val headers: List<String>,
    val rows: List<ScheduleRow>
)

@Immutable
data class ScheduleRow(
    val id: String = UUID.randomUUID().toString(),
    val cells: List<String>
)

@Immutable
data class CalendarEventModel(
    val id: String = UUID.randomUUID().toString(),
    val time: String,
    val subject: String,
    val link: String
)

@Immutable
data class CalendarDay(
    val id: String = UUID.randomUUID().toString(),
    val dateLabel: String,
    val events: List<CalendarEventModel>
)

@Immutable
data class ParsedSchedules(
    val schedules: List<ActivitySchedule>,
    val calendarDays: List<CalendarDay>,
    val sourceNotices: List<ScheduleSourceNotice> = emptyList(),
)

enum class ScheduleSource { ACTIVITY_SCHEDULES, CALENDAR }

@Immutable
data class ScheduleSourceNotice(val source: ScheduleSource, val usingSavedData: Boolean, val partial: Boolean = false)

/* ────────────────────────────── View Model ─────────────────────────────── */

class ScheduleViewModel : ViewModel() {
    private val _rawData = MutableStateFlow<Result<ParsedSchedules>?>(null)
    private val _isRefreshing = MutableStateFlow(false)
    private val _refreshError = MutableStateFlow<String?>(null)
    private var lastSuccessfulData: ParsedSchedules? = null

    // Calendar UI State
    private val _selectedDayId = MutableStateFlow<String?>(null)
    private val _searchQuery = MutableStateFlow("")

    val uiState: StateFlow<ScheduleUiState> = combine(
        _rawData, _selectedDayId, _searchQuery, _isRefreshing, _refreshError
    ) { result, dayId, query, refreshing, refreshError ->
        if (result == null && !refreshing) return@combine ScheduleUiState.Loading
        if (result == null) return@combine ScheduleUiState.Loading

        result.fold(
            onSuccess = { data ->
                val activeDayId = dayId?.takeIf { id -> data.calendarDays.any { it.id == id } }
                    ?: data.calendarDays.firstOrNull()?.id
                val activeDay = data.calendarDays.find { it.id == activeDayId }

                val filteredEvents = activeDay?.events?.filter {
                    it.subject.contains(query, ignoreCase = true) ||
                            it.time.contains(query, ignoreCase = true)
                } ?: emptyList()

                ScheduleUiState.Success(
                    data = data,
                    isRefreshing = refreshing,
                    selectedDayId = activeDayId,
                    searchQuery = query,
                    filteredEvents = filteredEvents,
                    refreshError = refreshError,
                )
            },
            onFailure = {
                ScheduleUiState.Error(it.message ?: "Unknown error", refreshing)
            }
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ScheduleUiState.Loading)

    init {
        loadData()
    }

    fun refresh() { loadData(forceRefresh = true) }
    fun revalidate() { loadData() }

    private fun loadData(forceRefresh: Boolean = false) {
        if (_isRefreshing.value) return
        _isRefreshing.value = true
        viewModelScope.launch {
            try {
                val data = RecreationScheduleCache.load(forceRefresh, lastSuccessfulData)
                lastSuccessfulData = data
                _refreshError.value = null
                _rawData.value = Result.success(data)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                val retained = lastSuccessfulData
                if (retained == null) _rawData.value = Result.failure(e)
                else {
                    _rawData.value = Result.success(retained)
                    _refreshError.value = "Couldn’t refresh schedules. Showing saved information."
                }
            } finally {
                _isRefreshing.value = false
            }
        }
    }

    fun selectDay(id: String) {
        _selectedDayId.value = id
    }

    fun updateSearch(query: String) {
        _searchQuery.value = query
    }
}

sealed interface ScheduleUiState {
    object Loading : ScheduleUiState
    data class Error(val message: String, val isRefreshing: Boolean) : ScheduleUiState
    data class Success(
        val data: ParsedSchedules,
        val isRefreshing: Boolean,
        val selectedDayId: String?,
        val searchQuery: String,
        val filteredEvents: List<CalendarEventModel>,
        val refreshError: String? = null,
    ) : ScheduleUiState
}

/* ────────────────────────────── UI Entry Point ─────────────────────────── */

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScheduleScreen(
    modifier: Modifier = Modifier,
    viewModel: ScheduleViewModel = viewModel()
) {
    TrackScreen("recreation")
    val state by viewModel.uiState.collectAsState()
    val pullRefreshState = rememberPullToRefreshState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(viewModel, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                viewModel.revalidate()
                kotlinx.coroutines.delay(60_000.milliseconds)
            }
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background
    ) { innerPadding ->
        val isRefreshing = (state as? ScheduleUiState.Success)?.isRefreshing
            ?: (state as? ScheduleUiState.Error)?.isRefreshing
            ?: false

        PullToRefreshBox(
            state = pullRefreshState,
            isRefreshing = isRefreshing,
            onRefresh = { viewModel.refresh() },
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            when (state) {
                is ScheduleUiState.Loading -> {
                    Box(Modifier.fillMaxSize(), Alignment.Center) {
                        Material3LoadingIndicator()
                    }
                }
                is ScheduleUiState.Error -> {
                    val msg = (state as ScheduleUiState.Error).message
                    ErrorView(message = msg, onRetry = { viewModel.refresh() })
                }
                is ScheduleUiState.Success -> {
                    val successState = state as ScheduleUiState.Success
                    ScheduleContent(
                        state = successState,
                        onDaySelected = viewModel::selectDay,
                        onSearchQuery = viewModel::updateSearch,
                        onRetry = viewModel::refresh,
                    )
                }
            }
        }
    }
}

@Composable
private fun ErrorView(message: String, onRetry: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            imageVector = Icons.Outlined.WifiOff,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.secondary
        )
        Spacer(Modifier.height(16.dp))
        Text("Unable to load schedules", style = MaterialTheme.typography.titleMedium)
        Text(
            text = message,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp)
        )
        Button(onClick = onRetry) { Text("Retry") }
    }
}

@Composable
private fun ScheduleContent(
    state: ScheduleUiState.Success,
    onDaySelected: (String) -> Unit,
    onSearchQuery: (String) -> Unit,
    onRetry: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = 16.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp)
    ) {
        state.refreshError?.let { message ->
            item(key = "refresh_error") {
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).semantics { liveRegion = LiveRegionMode.Polite }) {
                    Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    TextButton(onClick = onRetry, enabled = !state.isRefreshing) { Text("Retry") }
                }
            }
        }
        if (state.data.sourceNotices.none { it.source == ScheduleSource.ACTIVITY_SCHEDULES && !it.usingSavedData && !it.partial }) {
            item(key = "map") { BuildingMapSection(state.data.schedules) }
        }

        items(state.data.sourceNotices, key = { it.source.name }) { notice ->
            SourceNoticeCard(notice)
        }

        // 2. Calendar Widget
        if (state.data.calendarDays.isNotEmpty()) {
            item(key = "calendar") {
                CalendarWidget(
                    days = state.data.calendarDays,
                    selectedDayId = state.selectedDayId,
                    searchQuery = state.searchQuery,
                    filteredEvents = state.filteredEvents,
                    onDaySelected = onDaySelected,
                    onSearchQuery = onSearchQuery
                )
            }
        }
    }
}

@Composable
private fun SourceNoticeCard(notice: ScheduleSourceNotice) {
    val label = when (notice.source) {
        ScheduleSource.ACTIVITY_SCHEDULES -> "activity schedules"
        ScheduleSource.CALENDAR -> "recreation calendar"
    }
    Surface(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.tertiaryContainer,
        contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
    ) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.WifiOff, null, Modifier.size(20.dp))
            Spacer(Modifier.width(12.dp))
            Text(
                if (notice.partial) "Some facility schedules could not load. Pull to refresh and try again."
                else if (notice.usingSavedData) "Showing saved $label while Penn State reconnects."
                else "The Penn State $label source is temporarily unavailable.",
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

/* ────────────────────────────── Components ────────────────────────────── */

@Composable
private fun CalendarWidget(
    days: List<CalendarDay>,
    selectedDayId: String?,
    searchQuery: String,
    filteredEvents: List<CalendarEventModel>,
    onDaySelected: (String) -> Unit,
    onSearchQuery: (String) -> Unit
) {
    val haptic = LocalHapticFeedback.current
    val focusManager = LocalFocusManager.current

    // Material 3 Primary Container for the Calendar
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .animateContentSize(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
            contentColor = MaterialTheme.colorScheme.onSurface
        ),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 0.dp)
    ) {
        Column {
            // Header
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(Icons.Default.Today, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("All Events", style = MaterialTheme.typography.titleMedium)
            }

            HorizontalDivider(color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f))

            // Day Pills
            LazyRow(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 12.dp),
                contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(days, key = { it.id }) { day ->
                    val isSelected = day.id == selectedDayId
                    val containerColor = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surface
                    val contentColor = if (isSelected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface

                    Surface(
                        selected = isSelected,
                        onClick = {
                            if (isSelected) return@Surface
                            haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                            onDaySelected(day.id)
                        },
                        shape = MaterialTheme.shapes.medium,
                        color = containerColor,
                        contentColor = contentColor,
                        tonalElevation = 0.dp
                    ) {
                        Text(
                            text = day.dateLabel,
                            style = MaterialTheme.typography.labelLarge,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp)
                        )
                    }
                }
            }

            // Search Bar
            Column(modifier = Modifier.padding(8.dp)) {
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = onSearchQuery,
                    placeholder = { Text("Search events...") },
                    leadingIcon = { Icon(Icons.Default.Search, null) },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = MaterialTheme.colorScheme.primary,
                        unfocusedContainerColor = MaterialTheme.colorScheme.surface,
                        focusedContainerColor = MaterialTheme.colorScheme.surface
                    ),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() })
                )
            }

            // Short lists wrap their content; longer lists scroll within the height cap.
            val scrollState = rememberScrollState()
            LaunchedEffect(selectedDayId, searchQuery) { scrollState.scrollTo(0) }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 300.dp)
                    .padding(bottom = 8.dp)
            ) {
                if (filteredEvents.isEmpty()) {
                    Box(Modifier.fillMaxWidth().padding(vertical = 24.dp), Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(Icons.Default.Search, null, tint = MaterialTheme.colorScheme.onSurface.copy(0.5f))
                            Text(
                                "No events found",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurface.copy(0.5f)
                            )
                        }
                    }
                } else {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .verticalScroll(scrollState)
                            .padding(horizontal = 16.dp)
                    ) {
                        filteredEvents.forEachIndexed { index, event ->
                            EventRow(event)
                            if (index < filteredEvents.lastIndex) {
                                HorizontalDivider(
                                    modifier = Modifier.padding(start = 72.dp),
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun EventRow(event: CalendarEventModel) {
    val uriHandler = LocalUriHandler.current
    val context = LocalContext.current

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable {
                try {
                    uriHandler.openUri(event.link)
                } catch (_: Exception) {
                    val i = Intent(Intent.ACTION_VIEW, event.link.toUri())
                    context.startActivity(i)
                }
            }
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = event.time,
            style = MaterialTheme.typography.bodyMedium.copy(
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                fontWeight = FontWeight.Medium
            ),
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.width(72.dp)
        )

        Text(
            text = event.subject,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )

        Icon(
            imageVector = Icons.Default.ChevronRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f),
            modifier = Modifier.size(16.dp)
        )
    }
}

@Composable
internal fun ScheduleTableDisplay(table: ScheduleTable) {
    table.rows.forEach { row ->
        val location = row.cells.firstOrNull().orEmpty()
        val headers = table.headers.drop(1)
        val times = row.cells.drop(1)

        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            // Location Header with decorative marker
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(4.dp, 16.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(MaterialTheme.colorScheme.primary)
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = location,
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.Medium
                )
            }

            ContextualFlowRow(headers, times)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ContextualFlowRow(headers: List<String>, times: List<String>) {
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        headers.forEachIndexed { index, header ->
            val time = times.getOrNull(index)?.replace('\u00a0', ' ')?.trim()
                ?.takeIf { it.isNotEmpty() } ?: return@forEachIndexed

            Surface(
                color = MaterialTheme.colorScheme.surface, // Clean contrast against SecondaryContainer
                contentColor = MaterialTheme.colorScheme.onSurface,
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.widthIn(min = 80.dp)
            ) {
                Column(
                    modifier = Modifier.padding(vertical = 8.dp, horizontal = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = header.uppercase(),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.secondary,
                        fontSize = MaterialTheme.typography.labelSmall.fontSize * 0.9
                    )
                    Text(
                        text = time,
                        style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                        textAlign = TextAlign.Center
                    )
                }
            }
        }
    }
}

/* ────────────────────────────── Parser Logic ────────────────────────────── */

object ScheduleParser {
    private const val CAL_URL  = "https://pennstatecampusrec.org/Calendar/GetCalendarWidgetItems"
    private const val BASE_URL = "https://pennstatecampusrec.org"

    suspend fun fetchAndParse(previous: ParsedSchedules? = null): ParsedSchedules = withContext(Dispatchers.IO) {
        val (facilityResult, calendarResult) = coroutineScope {
            val facilities = async { runCatching { FacilitySchedules.load() }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it } }
            val calendar = async { runCatching {
                val response = Jsoup.connect(CAL_URL).timeout(20_000).execute()
                check(response.contentType()?.contains("text/html", true) == true)
                val document = response.parse()
                check(document.select("div.CalendarItem").isNotEmpty() || !response.body().contains("<html", true))
                parseCalendar(document)
            }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it } }
            facilities.await() to calendar.await()
        }
        if (facilityResult.isFailure && calendarResult.isFailure && previous == null) {
            throw IllegalStateException("Penn State Recreation is temporarily unavailable.")
        }
        val facilities = facilityResult.getOrNull()
        return@withContext ParsedSchedules(
            schedules = facilities?.schedules ?: previous?.schedules.orEmpty(),
            calendarDays = calendarResult.getOrNull() ?: previous?.calendarDays.orEmpty(),
            sourceNotices = buildList {
                if (facilityResult.isFailure) add(ScheduleSourceNotice(ScheduleSource.ACTIVITY_SCHEDULES, previous?.schedules?.isNotEmpty() == true))
                else if (facilities?.incomplete == true) add(ScheduleSourceNotice(ScheduleSource.ACTIVITY_SCHEDULES, false, partial = true))
                if (calendarResult.isFailure) add(ScheduleSourceNotice(ScheduleSource.CALENDAR, previous?.calendarDays?.isNotEmpty() == true))
            }
        )
    }

    internal fun parseCalendar(doc: Document): List<CalendarDay> =
        doc.select("div.CalendarItem").map { dayEl ->
            val label = dayEl.selectFirst("h3.NewsTitle")?.text().orEmpty()
            val events = dayEl.select("div.CalendarEvent").mapNotNull { ev ->
                val href    = ev.selectFirst("a[href]")?.attr("href") ?: return@mapNotNull null
                val link = java.net.URI(BASE_URL).resolve(href).toString()
                if (!link.startsWith("https://") && !link.startsWith("http://")) return@mapNotNull null
                val time    = ev.selectFirst("div.EventTime")?.text().orEmpty()
                val subject = ev.selectFirst("div.EventSubject")?.text().orEmpty()
                CalendarEventModel(time = time, subject = subject, link = link)
            }
            CalendarDay(id = label, dateLabel = label, events = events)
        }
}


/** A campus-day-scoped cache avoids six new facility requests on each tab visit. */
private object RecreationScheduleCache {
    private val mutex = kotlinx.coroutines.sync.Mutex()
    private var cached: ParsedSchedules? = null
    private var day: java.time.LocalDate? = null
    private var fetchedAt = 0L
    suspend fun load(forceRefresh: Boolean, previous: ParsedSchedules?): ParsedSchedules {
        mutex.lock()
        try {
            val today = java.time.LocalDate.now(java.time.ZoneId.of("America/New_York"))
            val now = android.os.SystemClock.elapsedRealtime()
            if (day != today) { cached = null; fetchedAt = 0 }
            val saved = cached
            if (!forceRefresh && saved != null && now - fetchedAt < 15 * 60_000 && saved.sourceNotices.isEmpty()) return saved
            val result = ScheduleParser.fetchAndParse(saved ?: previous.takeIf { day == today })
            cached = result
            day = today
            fetchedAt = android.os.SystemClock.elapsedRealtime()
            return result
        } finally { mutex.unlock() }
    }
}
