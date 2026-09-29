package com.ryannair05.meetandeat

import android.app.Application
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.spring
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import androidx.navigationevent.NavigationEvent
import com.ryannair05.meetandeat.dining.*
import kotlinx.serialization.Serializable
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

@Serializable data object DiscoverHomeRoute : NavKey
@Serializable data object DiningHomeRoute : NavKey
@Serializable data class DiningHallRoute(val hall: PSUDiningHall, val date: String? = null) : NavKey
@Serializable data class DiningItemRoute(
    val hall: PSUDiningHall,
    val date: String,
    val meal: String,
    val itemId: String,
    val itemName: String,
    val detailUrl: String?,
    val labels: List<String>,
    val includeAvailability: Boolean,
) : NavKey

@Composable
fun DiningHallListScreen(modifier: Modifier = Modifier) {
    val forward = if (androidx.compose.ui.platform.LocalLayoutDirection.current == androidx.compose.ui.unit.LayoutDirection.Rtl) -1 else 1
    val backStack = rememberNavBackStack(DiningHomeRoute)
    fun open(next: NavKey) { if (backStack.lastOrNull() != next) backStack.add(next) }
    fun back() { if (backStack.size > 1) backStack.removeLastOrNull() }
    NavDisplay(
        onBack = ::back,
        modifier = modifier.fillMaxSize(),
        backStack = backStack,
        entryDecorators = listOf(
            rememberSaveableStateHolderNavEntryDecorator(),
            rememberViewModelStoreNavEntryDecorator(),
        ),
        transitionSpec = {
            (slideInHorizontally(
                animationSpec = spring(dampingRatio = 1f, stiffness = 550f),
                initialOffsetX = { forward * it },
            ) + fadeIn(tween(150, delayMillis = 90))) togetherWith
                (slideOutHorizontally(
                    animationSpec = spring(dampingRatio = 1f, stiffness = 550f),
                    targetOffsetX = { -forward * it / 5 },
                ) + fadeOut(tween(100)))
        },
        popTransitionSpec = {
            (slideInHorizontally(
                animationSpec = spring(dampingRatio = 1f, stiffness = 550f),
                initialOffsetX = { -forward * it / 5 },
            ) + fadeIn(tween(140))) togetherWith
                (slideOutHorizontally(
                    animationSpec = spring(dampingRatio = 1f, stiffness = 550f),
                    targetOffsetX = { forward * it },
                ) + fadeOut(tween(100)))
        },
        predictivePopTransitionSpec = { swipeEdge ->
            val direction = if (swipeEdge == NavigationEvent.EDGE_RIGHT) -1 else 1
            slideInHorizontally(
                animationSpec = spring(dampingRatio = 1f, stiffness = 550f),
                initialOffsetX = { -direction * it / 5 },
            ) togetherWith slideOutHorizontally(
                animationSpec = spring(dampingRatio = 1f, stiffness = 550f),
                targetOffsetX = { direction * it },
            )
        },
        entryProvider = entryProvider {
            entry<DiscoverHomeRoute> {
                com.ryannair05.meetandeat.discover.DiscoverFeature(onBack = ::back)
            }
            entry<DiningHomeRoute> {
                val application = LocalContext.current.applicationContext as Application
                val vm: DiningListViewModel = viewModel(factory = remember {
                    simpleViewModelFactory { DiningListViewModel(application) }
                })
                DiningLandingScreen(
                    vm,
                    onDiscover = { open(DiscoverHomeRoute) },
                    onHall = { open(DiningHallRoute(it)) },
                    onItem = { result ->
                        val appearance = result.appearances.first()
                        open(
                            result.item.toRoute(
                                appearance.hall,
                                appearance.date,
                                appearance.mealNames.firstOrNull().orEmpty(),
                                includeAvailability = true,
                            )
                        )
                    },
                )
            }
            entry<DiningHallRoute> { route ->
                DiningHallDetailScreen(
                    diningHall = route.hall,
                    initialDate = route.date?.let(LocalDate::parse),
                    onBack = ::back,
                    onItem = { date, meal, item ->
                        open(item.toRoute(route.hall, date, meal, includeAvailability = false))
                    },
                )
            }
            entry<DiningItemRoute> { route ->
                MenuItemDetailScreen(
                    route = route,
                    onBack = ::back,
                    onOpenHall = { hall, date -> open(DiningHallRoute(hall, date.toString())) },
                )
            }
        },
    )
}

private fun DiningMenuItem.toRoute(
    hall: PSUDiningHall,
    date: LocalDate,
    meal: String,
    includeAvailability: Boolean,
) = DiningItemRoute(
    hall, date.toString(), meal, id, name, detailUrl, sourceLabels, includeAvailability,
)

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun DiningLandingScreen(
    vm: DiningListViewModel,
    onDiscover: () -> Unit,
    onHall: (PSUDiningHall) -> Unit,
    onItem: (DiningSearchResult) -> Unit,
) {
    TrackScreen("dining_halls")
    val state by vm.state.collectAsState()
    var filterExpanded by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val hallListState = rememberLazyListState()
    val scrollBehavior = SearchBarDefaults.enterAlwaysSearchBarScrollBehavior(scrollState = rememberSearchBarScrollState())
    val searchState = rememberSearchBarState()
    val scope = rememberCoroutineScope()
    val resultsState = rememberLazyListState()
    val showingResults = state.searchQuery.trim().length >= 3
    val openSearchItem: (DiningSearchResult) -> Unit = { result ->
        scope.launch { searchState.animateToCollapsed(); onItem(result) }
    }
    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = MaterialTheme.colorScheme.surface,
        topBar = {
            Column {
                DiningSearchAppBar(
                    state = searchState,
                    query = state.searchQuery,
                    onQueryChange = vm::setSearchQuery,
                    title = "PSU Dining",
                    searchHint = "Search every dining hall",
                    scrollBehavior = scrollBehavior,
                    actions = {
                        Box {
                            IconButton(onClick = { filterExpanded = true }) {
                                Icon(
                                    DiningSymbols.FilterList,
                                    if (state.filter.isEmpty) "Dietary filters" else "Dietary filters active",
                                    tint = if (state.filter.isEmpty) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary,
                                )
                            }
                            DietaryFilterMenu(
                                filterExpanded, state.filter.required, { filterExpanded = false },
                                vm::toggleFilter, vm::clearFilters,
                            )
                        }
                    },
                ) {
                    ActiveDietaryFilters(state.filter.required, vm::toggleFilter, vm::clearFilters)
                    if (showingResults) {
                        SearchResults(state.searchResults, state.isSearching, state.searchedHallCount,
                            rememberLazyListState(), openSearchItem)
                    } else {
                        Text("Search dishes across every dining hall", Modifier.padding(DiningSpacing.page),
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                ActiveDietaryFilters(state.filter.required, vm::toggleFilter, vm::clearFilters)

            }
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = state.isRefreshing,
            onRefresh = vm::refresh,
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            if (showingResults) {
                SearchResults(state.searchResults, state.isSearching, state.searchedHallCount, resultsState, onItem)
            } else {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize().testTag("dining-hall-grid"),
                        state = hallListState,
                        contentPadding = PaddingValues(top = 16.dp, bottom = 24.dp),
                    ) {
                        items(PSUDiningHall.entries, key = { it.id }) { hall ->
                            DiningHallRow(hall, if (state.hoursLoading && state.hours[hall] == null) "Loading hours…" else state.hours[hall].statusText(), { onHall(hall) },
                                { openOfficialMenu(context, hall) }, { openInMaps(context, hall) })
                            Spacer(Modifier.height(8.dp))
                        }
                        item { SectionHeader("Other locations", Modifier.padding(horizontal = 16.dp), topPadding = 8.dp) }
                        item {
                            ListItem(
                                supportingContent = { Text("Order food for pickup") },
                                leadingContent = { DiningShortcutIcon(DiningSymbols.Restaurant) },
                                trailingContent = { Icon(DiningSymbols.ChevronRight, null) },
                                colors = ListItemDefaults.colors(containerColor = diningCellColor()),
                                modifier = Modifier.fillMaxWidth(),
                                onClick = { openPsuEats(context) },
                                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                            ) { Text("PSU Eats") }
                            Spacer(Modifier.height(8.dp))
                        }
                        item {
                            ListItem(
                                supportingContent = { Text("Campus events and student clubs") },
                                leadingContent = { DiningShortcutIcon(com.ryannair05.meetandeat.discover.DiscoverSymbols.Explore, discover = true) },
                                trailingContent = { Icon(DiningSymbols.ChevronRight, null) },
                                colors = ListItemDefaults.colors(containerColor = diningCellColor()),
                                modifier = Modifier.fillMaxWidth(),
                                onClick = onDiscover,
                                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                            ) { Text("Discover") }
                        }
                    }
            }
        }
    }
}

@Composable
private fun SearchResults(
    results: List<DiningSearchResult>,
    loading: Boolean,
    coverage: Int,
    listState: androidx.compose.foundation.lazy.LazyListState,
    onItem: (DiningSearchResult) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        state = listState,
        contentPadding = PaddingValues(vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item(key = "search_status") {
            Column {
                if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(
                    if (loading) "Searching menus · $coverage of ${PSUDiningHall.entries.size} checked" else "${results.size} dishes found",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
        if (!loading && results.isEmpty()) {
            item(key = "empty") {
                DiningEmptyState("No matching dishes", "Try another search or adjust dietary filters.")
            }
        }
            items(results, key = { it.item.id + it.item.name }) { result ->
                MenuFoodRow(result.item, { onItem(result) },
                    result.appearances.joinToString(" · ") { "${it.hall.displayName}: ${it.mealNames.joinToString()}" })
            }
    }
}

@Composable
internal fun DietaryFilterMenu(
    expanded: Boolean,
    selected: Set<DietaryRequirement>,
    onDismiss: () -> Unit,
    onToggle: (DietaryRequirement) -> Unit,
    onClear: () -> Unit,
) {
    DropdownMenu(expanded, onDismiss) {
        DietaryRequirement.entries.forEach { requirement ->
            DropdownMenuItem(
                text = { Text(requirement.displayName) },
                onClick = { onToggle(requirement) },
                leadingIcon = { MenuTraitIcon(requirement.trait, Modifier.size(24.dp)) },
                trailingIcon = { Checkbox(requirement in selected, onCheckedChange = null) },
            )
        }
        if (selected.isNotEmpty()) DropdownMenuItem({ Text("Clear filters", color = MaterialTheme.colorScheme.error) }, onClick = onClear)
    }
}

@Composable
internal fun ActiveDietaryFilters(
    selected: Set<DietaryRequirement>,
    onRemove: (DietaryRequirement) -> Unit,
    onClear: () -> Unit,
) {
    if (selected.isEmpty()) return
    LazyRow(
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items(DietaryRequirement.entries.filter { it in selected }, key = { it.name }) { requirement ->
            InputChip(
                selected = true,
                onClick = { onRemove(requirement) },
                label = { Text(requirement.displayName) },
                leadingIcon = { MenuTraitIcon(requirement.trait, Modifier.size(20.dp)) },
                trailingIcon = { Icon(DiningSymbols.Close, "Remove ${requirement.displayName} filter", Modifier.size(16.dp)) },
            )
        }
        item { TextButton(onClick = onClear) { Text("Clear all") } }
    }
}

@Composable
internal fun TraitText(item: DiningMenuItem) {
    val traits = remember(item.sourceLabels, item.name) { MenuTraitClassifier.classify(item.sourceLabels, item.name) }
    val visibleTraits = remember(traits) { traits.withoutGenericAllergenWarning() }
    if (visibleTraits.isNotEmpty()) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            visibleTraits.forEach { trait ->
                MenuTraitIcon(
                    trait,
                    contentDescription = trait.displayName,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

fun openOfficialMenu(context: Context, hall: PSUDiningHall) {
    val date = LocalDate.now(PennStateZone).format(DateTimeFormatter.ofPattern("MM/dd/yyyy", Locale.US))
    val uri = "https://www.absecom.psu.edu/menus/user-pages/daily-menu.cfm?selMenuDate=$date&selCampus=${hall.menuNumber}".toUri()
    runCatching { CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, uri) }
        .onFailure { context.startActivity(Intent(Intent.ACTION_VIEW, uri)) }
}

fun openInMaps(context: Context, hall: PSUDiningHall) {
    val uri = "geo:${hall.latitude},${hall.longitude}?q=${hall.latitude},${hall.longitude}(${hall.displayName}+Dining)".toUri()
    val maps = Intent(Intent.ACTION_VIEW, uri).setPackage("com.google.android.apps.maps")
    context.startActivity(if (maps.resolveActivity(context.packageManager) != null) maps else Intent(Intent.ACTION_VIEW, uri))
}

private fun openPsuEats(context: Context) {
    val uri = "https://weborder.transactcampus.com/237".toUri()
    try { CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, uri) }
    catch (_: ActivityNotFoundException) { context.startActivity(Intent(Intent.ACTION_VIEW, uri)) }
}
