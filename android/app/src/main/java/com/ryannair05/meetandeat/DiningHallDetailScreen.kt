package com.ryannair05.meetandeat

import android.app.Application
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Button
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSearchBarState
import androidx.compose.material3.Surface
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.ryannair05.meetandeat.dining.DiningMenuItem
import com.ryannair05.meetandeat.dining.DiningMenuUiState
import com.ryannair05.meetandeat.dining.DiningMenuViewModel
import com.ryannair05.meetandeat.dining.DiningServiceStatus
import com.ryannair05.meetandeat.dining.DiningServiceStatusKind
import com.ryannair05.meetandeat.dining.LoadState
import com.ryannair05.meetandeat.dining.PSUDiningHall
import com.ryannair05.meetandeat.dining.PennStateStationHours
import com.ryannair05.meetandeat.dining.PennStateZone
import com.ryannair05.meetandeat.dining.formatMinutes
import com.ryannair05.meetandeat.dining.statusText
import com.ryannair05.meetandeat.dining.serviceStatus
import com.ryannair05.meetandeat.dining.simpleViewModelFactory
import com.ryannair05.meetandeat.share.MenuShareSheet
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlin.math.roundToInt
import kotlin.time.Duration.Companion.milliseconds

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun DiningHallDetailScreen(
    diningHall: PSUDiningHall,
    initialDate: LocalDate? = null,
    onBack: () -> Unit = {},
    onItem: (LocalDate, String, DiningMenuItem) -> Unit = { _, _, _ -> },
) {
    TrackScreen("dining_hall", "dining_hall_${diningHall.id}")
    val context = LocalContext.current
    val application = context.applicationContext as Application
    var retainedDate by rememberSaveable(diningHall) { mutableStateOf((initialDate ?: LocalDate.now(PennStateZone)).toString()) }
    var retainedMeal by rememberSaveable(diningHall) { mutableStateOf<String?>(null) }
    var retainedQuery by rememberSaveable(diningHall) { mutableStateOf("") }
    val vm: DiningMenuViewModel = viewModel(
        key = "menu-${diningHall.id}-${initialDate ?: "today"}",
        factory = remember(diningHall, initialDate) {
            simpleViewModelFactory { DiningMenuViewModel(application, diningHall, LocalDate.parse(retainedDate), retainedMeal, retainedQuery) }
        },
    )
    val state by vm.state.collectAsState()
    SideEffect {
        retainedDate = state.date.toString()
        retainedMeal = state.selectedMealId
        retainedQuery = state.searchQuery
    }
    val selectedMeal = state.selectedMeal
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val now by produceState(java.time.ZonedDateTime.now(PennStateZone), vm, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                value = java.time.ZonedDateTime.now(PennStateZone)
                vm.revalidate()
                kotlinx.coroutines.delay(60_000.milliseconds)
            }
        }
    }
    val serviceStatus = remember(state.dayHours, selectedMeal?.name, state.date, now) {
        state.dayHours.serviceStatus(selectedMeal?.name, state.date, now)
    }
    var datePickerVisible by remember { mutableStateOf(false) }
    var filterVisible by remember { mutableStateOf(false) }
    var shareVisible by remember { mutableStateOf(false) }
    var plateVisible by rememberSaveable { mutableStateOf(false) }
    val searchState = rememberSearchBarState()
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current

    val mealPicker: @Composable () -> Unit = {
                state.snapshot?.meals?.takeIf { it.isNotEmpty() }?.let { meals ->
                    val mealScrollState = rememberScrollState()
                    val selectedIndex = meals.indexOfFirst { it.id == state.selectedMealId }.coerceAtLeast(0)
                    val maxMealScroll = mealScrollState.maxValue
                    LaunchedEffect(selectedIndex, meals.size, maxMealScroll) {
                        if (maxMealScroll != Int.MAX_VALUE) {
                            val progress = selectedIndex.toFloat() / meals.lastIndex.coerceAtLeast(1)
                            mealScrollState.animateScrollTo((maxMealScroll * progress).roundToInt())
                        }
                    }
                    SingleChoiceSegmentedButtonRow(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(mealScrollState),
                    ) {
                        meals.forEachIndexed { index, meal ->
                            SegmentedButton(
                                modifier = Modifier.widthIn(min = 92.dp).heightIn(min = 48.dp),
                                selected = state.selectedMealId == meal.id,
                                onClick = { haptics.performHapticFeedback(HapticFeedbackType.SegmentTick); vm.selectMeal(meal.id) },
                                shape = SegmentedButtonDefaults.itemShape(index, meals.size),
                                colors = SegmentedButtonDefaults.colors(
                                    activeContainerColor = MaterialTheme.colorScheme.primary,
                                    activeContentColor = MaterialTheme.colorScheme.onPrimary,
                                    activeBorderColor = MaterialTheme.colorScheme.primary,
                                ),
                                icon = {},
                                label = { Text(meal.name) },
                            )
                        }
                    }
                }
    }

    val menuHeader: @Composable () -> Unit = {
        mealPicker()
        if (state.isMenuLoading && state.snapshot != null) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                if (state.hoursLoading && state.dayHours == null) {
                    Text("Loading hours…", style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else if (state.selectedMeal == null && state.isMenuLoading) {
                    Text(state.dayHours.statusText(), style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else DiningServiceStatusView(status = serviceStatus)
            }
            TextButton(onClick = { datePickerVisible = true }) {
                Icon(DiningSymbols.CalendarMonth, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(state.date.format(DateTimeFormatter.ofPattern("MMM d")))
            }
        }

    }

    val onSwipeMeal: (Int) -> Unit = { direction ->
        val meals = state.snapshot?.meals.orEmpty()
        val index = meals.indexOfFirst { it.id == state.selectedMealId }
        val next = (index + direction).coerceIn(0, meals.lastIndex.coerceAtLeast(0))
        meals.getOrNull(next)?.let { if (it.id != state.selectedMealId) vm.selectMeal(it.id) }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.surface,
        topBar = {
            Column {
                DiningSearchAppBar(
                    state = searchState,
                    compact = true,
                    query = state.searchQuery,
                    onQueryChange = vm::setSearchQuery,
                    title = diningHall.displayName,
                    searchHint = "Search ${state.selectedMeal?.name ?: "menu"}",
                    navigationIcon = { IconButton(onClick = onBack) { Icon(DiningSymbols.ArrowBack, "Back") } },
                    actions = {
                        IconButton(enabled = selectedMeal != null, onClick = { plateVisible = true }) {
                            Icon(DiningSymbols.Restaurant, "Build a plate")
                        }

                        Box {
                            IconButton(onClick = { filterVisible = true }) {
                                Icon(
                                    DiningSymbols.FilterList,
                                    if (state.filter.isEmpty) "Dietary filters" else "Dietary filters active",
                                    tint = if (state.filter.isEmpty) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary,
                                )
                            }
                            DietaryFilterMenu(filterVisible, state.filter.required, { filterVisible = false }, vm::toggleFilter, vm::clearFilters)
                        }
                        IconButton(
                            onClick = { shareVisible = true },
                            enabled = state.selectedMeal != null,
                        ) { Icon(DiningSymbols.Share, "Share current meal") }
                    },
                ) {
                    ActiveDietaryFilters(state.filter.required, vm::toggleFilter, vm::clearFilters)
                    MenuBody(state, onRetry = vm::refresh, onItem = { date, meal, item ->
                        scope.launch { searchState.animateToCollapsed(); onItem(date, meal, item) }
                    }, onSwipe = onSwipeMeal)
                }
                ActiveDietaryFilters(state.filter.required, vm::toggleFilter, vm::clearFilters)
                Surface(color = diningHeaderColor()) {
                    Column(Modifier.padding(horizontal = 16.dp)) { menuHeader() }
                }

            }
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = state.isRefreshing,
            onRefresh = vm::refresh,
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            MenuBody(state, onRetry = vm::refresh, onItem = onItem, onSwipe = onSwipeMeal)
        }
    }

    if (datePickerVisible) {
        val today = LocalDate.now(PennStateZone)
        val dateState = rememberDatePickerState(
            initialSelectedDateMillis = state.date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    val date = Instant.ofEpochMilli(utcTimeMillis).atZone(ZoneOffset.UTC).toLocalDate()
                    return !date.isBefore(today.minusDays(1)) && !date.isAfter(today.plusDays(7))
                }
            },
        )
        DatePickerDialog(
            onDismissRequest = { datePickerVisible = false },
            confirmButton = {
                TextButton(onClick = {
                    dateState.selectedDateMillis?.let { millis -> vm.selectDate(Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate()) }
                    datePickerVisible = false
                }) { Text("Done") }
            },
            dismissButton = { TextButton(onClick = { datePickerVisible = false }) { Text("Cancel") } },
        ) { DatePicker(dateState, title = { Text("Choose menu date", Modifier.padding(24.dp)) }) }
    }
    if (plateVisible) selectedMeal?.let { meal ->
        com.ryannair05.meetandeat.journal.PlateEditor(diningHall, state.date, meal.name, meal.sections.flatMap { it.items }, onDismiss = { plateVisible = false })
    }
    if (shareVisible) state.selectedMeal?.let { meal ->
        MenuShareSheet(
            hall = state.hall,
            date = state.date,
            meal = meal,
            onDismiss = { shareVisible = false },
        )
    }
}

@Composable
private fun DiningServiceStatusView(status: DiningServiceStatus, modifier: Modifier = Modifier) {
    val statusColor = when (status.kind) {
        DiningServiceStatusKind.OPEN -> diningOpenColor()
        DiningServiceStatusKind.UPCOMING -> diningUpcomingColor()
        DiningServiceStatusKind.CLOSED -> MaterialTheme.colorScheme.error
        DiningServiceStatusKind.UNAVAILABLE -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        status.serviceWindow?.let { window ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(DiningSymbols.AccessTime, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(6.dp))
                Text(
                    window,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                status.status,
                style = MaterialTheme.typography.labelMedium,
                color = statusColor,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
internal fun diningOpenColor(): Color = MaterialTheme.colorScheme.primary

@Composable
internal fun diningUpcomingColor(): Color = MaterialTheme.colorScheme.tertiary

@Composable
private fun MenuBody(
    state: DiningMenuUiState,
    onRetry: () -> Unit,
    onItem: (LocalDate, String, DiningMenuItem) -> Unit,
    onSwipe: (Int) -> Unit,
) {
    when (val load = state.snapshotState) {
        LoadState.Idle, is LoadState.Loading -> {
            if (load is LoadState.Loading && load.cached != null) MenuSections(state, onItem, onSwipe)
            else DiningLoadingState("Loading ${state.hall.displayName}'s menu")
        }
        is LoadState.Empty -> DiningEmptyState("No menu published", load.message)
        is LoadState.Error -> {
            if (load.cached != null) {
                Column { ErrorBanner(load.message, onRetry); MenuSections(state, onItem, onSwipe) }
            } else DiningErrorState("Couldn't load menu", load.message, onRetry)
        }
        is LoadState.Ready -> MenuSections(state, onItem, onSwipe)
    }
}

@Composable
private fun MenuSections(
    state: DiningMenuUiState,
    onItem: (LocalDate, String, DiningMenuItem) -> Unit,
    onSwipe: (Int) -> Unit,
) {
    var dragAmount by remember { mutableFloatStateOf(0f) }
    val layoutDirection = LocalLayoutDirection.current
    val velocityTracker = remember { VelocityTracker() }
    AnimatedContent(
        targetState = state,
        contentKey = { it.selectedMealId },
        transitionSpec = {
            (slideInHorizontally(spring(dampingRatio = 1f, stiffness = 550f)) { it / 5 } + fadeIn()) togetherWith
                (slideOutHorizontally(spring(dampingRatio = 1f, stiffness = 550f)) { -it / 5 } + fadeOut())
        },
        label = "meal",
    ) { mealState ->
        val visibleSections = remember(mealState.snapshot, mealState.selectedMealId, mealState.searchQuery, mealState.filter) {
            mealState.visibleSections
        }
        val listState = rememberLazyListState()
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().pointerInput(mealState.selectedMealId, layoutDirection) {
                detectHorizontalDragGestures(
                    onDragStart = { dragAmount = 0f; velocityTracker.resetTracking() },
                    onHorizontalDrag = { change, amount ->
                        dragAmount += amount
                        velocityTracker.addPosition(change.uptimeMillis, change.position)
                    },
                    onDragCancel = { dragAmount = 0f; velocityTracker.resetTracking() },
                    onDragEnd = {
                        val velocity = velocityTracker.calculateVelocity().x
                        val distanceThreshold = 44.dp.toPx()
                        val direction = if (kotlin.math.abs(dragAmount) >= distanceThreshold) dragAmount
                            else if (kotlin.math.abs(velocity) >= 500.dp.toPx()) velocity else 0f
                        val adjusted = if (layoutDirection == LayoutDirection.Rtl) -direction else direction
                        if (adjusted > 0f) onSwipe(-1) else if (adjusted < 0f) onSwipe(1)
                    },
                )
            },
            contentPadding = PaddingValues(bottom = 8.dp),
        ) {
            if (mealState.selectedMealId in mealState.snapshot?.pendingMealIds.orEmpty()) {
                item(key = "meal_pending") {
                    if (mealState.isMenuLoading) DiningLoadingState("Loading ${mealState.selectedMeal?.name ?: "meal"}…")
                    else Text("This meal couldn't be loaded. Retry to load the remaining meals.",
                        Modifier.padding(vertical = 24.dp), style = MaterialTheme.typography.bodyLarge)
                }
            } else if (mealState.selectedMeal?.sections?.isEmpty() == true) {
                item(key = "meal_empty") {
                    DiningEmptyState("No items published", "No items were published for this meal.")
                }
            } else if (visibleSections.isEmpty()) {
                item(key = "no_matches") {
                    DiningEmptyState("Nothing matches", "Try another search or clear a dietary filter.")
                }
            }
            visibleSections.forEachIndexed { index, section ->
                item(key = section.id) {
                    val hours = mealState.stationHours[PennStateStationHours.key(mealState.hall, section.name)]
                    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                        SectionHeader(section.name, topPadding = if (index == 0) 4.dp else 16.dp)
                        if (hours?.explicitlyClosed == true) {
                            Text("Closed on this date · PSU still lists the items below.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                        } else if (hours?.intervals?.isNotEmpty() == true) {
                            Text("Location hours · " + hours.intervals.distinct().joinToString(" · ") {
                                "${formatMinutes(it.startMinutes)}–${formatMinutes(it.endMinutes)}"
                            }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                items(section.items, key = { "${section.id}-${it.id}-${it.sourceOrder}" }) { item ->
                    MenuFoodRow(item, onClick = { onItem(mealState.date, mealState.selectedMeal?.name.orEmpty(), item) })
                }
            }
            item { Spacer(Modifier.height(16.dp)) }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
internal fun DiningLoadingState(label: String) = Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        LoadingIndicator()
        Spacer(Modifier.height(16.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun Material3LoadingIndicator() = LoadingIndicator()

@Composable
internal fun DiningEmptyState(title: String, message: String) =
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Text(message, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }

@Composable
private fun DiningErrorState(title: String, message: String, onRetry: () -> Unit) =
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(DiningSymbols.WifiOff, null, Modifier.size(56.dp), tint = MaterialTheme.colorScheme.error)
            Spacer(Modifier.height(16.dp))
            Text(title, style = MaterialTheme.typography.headlineSmall)
            Text(message, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(16.dp))
            Button(onClick = onRetry) { Text("Try again") }
        }
    }

@Composable
private fun ErrorBanner(message: String, onRetry: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.errorContainer, contentColor = MaterialTheme.colorScheme.onErrorContainer) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(message, Modifier.weight(1f).padding(horizontal = 12.dp), style = MaterialTheme.typography.bodyMedium)
            TextButton(onClick = onRetry) { Text("Retry") }
        }
    }
}
