@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.material3.ExperimentalMaterial3ExpressiveApi::class)

package com.ryannair05.meetandeat.discover

import android.app.Application
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import coil3.compose.AsyncImage
import com.ryannair05.meetandeat.DiningSearchAppBar
import com.ryannair05.meetandeat.diningCellColor
import com.ryannair05.meetandeat.DiningSymbols
import com.ryannair05.meetandeat.TrackScreen
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.format.DateTimeFormatter

@Serializable private data class DiscoverRoute(val page: String = "home", val id: String = "") : NavKey

@Composable
internal fun DiscoverFeature(onBack: () -> Unit) {
    val application = LocalContext.current.applicationContext as Application
    val vm: DiscoverViewModel = viewModel(factory = remember {
        viewModelFactory { initializer { DiscoverViewModel(application, createSavedStateHandle()) } }
    })
    val state by vm.state.collectAsState()
    val stack = rememberNavBackStack(DiscoverRoute())
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner, vm) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) { vm.tick(); vm.refresh() } }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(vm) { while (true) { delay(60_000); vm.tick() } }
    val back: () -> Unit = { if (stack.size > 1) stack.removeLastOrNull() else onBack() }
    NavDisplay(
        backStack = stack, onBack = back,
        entryDecorators = listOf(rememberSaveableStateHolderNavEntryDecorator()),
        entryProvider = entryProvider {
            entry<DiscoverRoute> { route ->
                DiscoverScreen(route, vm, state, back) { next -> if (stack.lastOrNull() != next) stack.add(next) }
            }
        },
    )
}

@Composable
private fun DiscoverScreen(route: DiscoverRoute, vm: DiscoverViewModel, state: DiscoverUiState, back: () -> Unit, open: (DiscoverRoute) -> Unit) {
    TrackScreen("discover_${route.page}")
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val actions = remember(context) { DiscoverActions(context) { message -> scope.launch { snackbar.showSnackbar(message) } } }
    val searchState = rememberSearchBarState()
    var filtersVisible by rememberSaveable(route) { mutableStateOf(false) }
    var moreVisible by remember { mutableStateOf(false) }
    // Only a user pull starts the refresh indicator. Cache/network results arriving
    // during initial loading must not turn the inline loader into a second spinner.
    var showPullRefresh by remember { mutableStateOf(false) }
    LaunchedEffect(state.loading) { if (!state.loading) showPullRefresh = false }
    val club = state.club(route.id)
    val event = state.event(route.id)
    val title = when (route.page) { "home" -> "Discover"; "events" -> "Events"; "clubs" -> "Clubs"; "saved" -> "Saved"; else -> "" }
    val navigateFromSearch: (DiscoverRoute) -> Unit = { next -> scope.launch { searchState.animateToCollapsed(); open(next) } }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.surface,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            if (route.page == "events" || route.page == "clubs") {
                val isEvents = route.page == "events"
                DiningSearchAppBar(searchState, if (isEvents) state.filters.eventQuery else state.filters.clubQuery,
                    onQueryChange = { query -> vm.filter { if (isEvents) it.copy(eventQuery = query) else it.copy(clubQuery = query) } },
                    title = title, searchHint = if (isEvents) "Search campus events" else "Search University Park clubs",
                    navigationIcon = { IconButton(onClick = back) { Icon(DiningSymbols.ArrowBack, "Back") } },
                    actions = {},
                ) {
                    if (isEvents) EventList(vm, state, navigateFromSearch, filtersVisible) { filtersVisible = !filtersVisible } else ClubList(vm, state, navigateFromSearch)
                }
            } else {
                TopAppBar(title = { Text(title) }, navigationIcon = { IconButton(onClick = back) { Icon(DiningSymbols.ArrowBack, "Back") } },
                    actions = {
                        if (route.page == "club" && club != null) {
                            SaveButton(club.id in state.saved.organizations, state.canSave && !state.saving) { vm.toggle(club) }
                            if (club.officialUrl != null) IconButton(onClick = { actions.share(club.officialUrl) }) { Icon(DiningSymbols.Share, "Share club") }
                        }
                        if (route.page == "event" && event != null) {
                            SaveButton(event.id in state.saved.events, state.canSave && !state.saving) { vm.toggle(event) }
                            if (event.officialUrl != null) IconButton(onClick = { actions.share(event.officialUrl) }) { Icon(DiningSymbols.Share, "Share event") }
                            if (!event.cancelled || event.officialUrl != null) Box {
                                IconButton(onClick = { moreVisible = true }) { Icon(DiningSymbols.MoreVert, "Event actions") }
                                DropdownMenu(moreVisible, { moreVisible = false }) {
                                    if (!event.cancelled) DropdownMenuItem({ Text("Add to Calendar") }, { moreVisible = false; actions.calendar(event) })
                                    if (event.officialUrl != null) DropdownMenuItem({ Text("Open in Discover") }, { moreVisible = false; actions.open(event.officialUrl) })
                                }
                            }
                        }
                    })
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
            val hasContent = when (route.page) {
                "home", "events" -> state.snapshot.eventsUpdated != null
                "clubs" -> state.snapshot.organizationsUpdated != null
                "saved" -> state.canSave
                "club" -> club != null
                "event" -> event != null
                else -> false
            }
            PullToRefreshBox(state.loading && showPullRefresh, onRefresh = {
                if (!state.loading) {
                    showPullRefresh = hasContent
                    vm.refresh(true)
                }
            }, modifier = Modifier.widthIn(max = 840.dp).fillMaxSize()) {
                when (route.page) {
                    "home" -> Home(vm, state, open, filtersVisible) { filtersVisible = !filtersVisible }
                    "events" -> EventList(vm, state, open, filtersVisible) { filtersVisible = !filtersVisible }
                    "clubs" -> ClubList(vm, state, open)
                    "saved" -> SavedList(vm, state, open)
                    "club" -> if (club != null) ClubDetail(club, vm, state, actions, open) else MissingDetail(state.loading)
                    "event" -> if (event != null) EventDetail(event, vm, state, actions, open) else MissingDetail(state.loading)
                }
            }
        }
    }
}

@Composable
private fun Home(vm: DiscoverViewModel, state: DiscoverUiState, open: (DiscoverRoute) -> Unit, filtersExpanded: Boolean, toggleFilters: () -> Unit) {
    val matches = vm.events(state, home = true)
    val events = matches.filterNot { it.ongoing(state.now) }
    val ongoing = matches.filter { it.ongoing(state.now) }
    fun browse() { vm.filter { it.forEventBrowse() }; open(DiscoverRoute("events")) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 24.dp, top = 16.dp, end = 24.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledTonalButton(onClick = { open(DiscoverRoute("clubs")) }) { Icon(DiscoverSymbols.Groups, null, tint = discoverIconColor(DiscoverSymbols.Groups)); Spacer(Modifier.width(8.dp)); Text("Explore clubs") }
                FilledTonalButton(onClick = { open(DiscoverRoute("saved")) }) { Icon(DiscoverSymbols.Bookmark, null, tint = discoverIconColor(DiscoverSymbols.Bookmark)); Spacer(Modifier.width(8.dp)); Text("Saved") }
            }
        }
        status(vm, state)
        item {
            Heading(if (state.snapshot.eventsUpdated == null) "On campus" else "On campus · ${matches.size}")
            DiscoverFilterControls(vm, state, filtersExpanded, toggleFilters, home = true)
        }

        if (state.snapshot.eventsUpdated == null && state.loading) item { LoadingContent("Loading campus events…") }
        else if (matches.isEmpty()) item { EmptyContent("No matching events", "Try another day or remove a filter.", "Show all upcoming") { vm.filter { it.resetEventFilters(home = true).copy(homeDate = DiscoverDate.UPCOMING) } } }
        items(events.take(5), key = { "event-${it.id}" }) { event -> EventRow(event, event.id in state.saved.events, { open(DiscoverRoute("event", event.id)) }) }
        item { TextButton(onClick = ::browse) { Text("See all events") } }
        if (ongoing.isNotEmpty()) {
            item { Heading("Ongoing on campus"); Text("Exhibitions, opportunities, and longer-running events.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            items(ongoing.take(2), key = { "ongoing-${it.id}" }) { event -> EventRow(event, event.id in state.saved.events, { open(DiscoverRoute("event", event.id)) }) }
            item { TextButton(onClick = ::browse) { Text("See all ongoing events") } }
        }
    }
}

@Composable
private fun EventList(vm: DiscoverViewModel, state: DiscoverUiState, open: (DiscoverRoute) -> Unit, filtersExpanded: Boolean, toggleFilters: () -> Unit) {
    val matches = vm.events(state, false)
    val regular = matches.filterNot { it.ongoing(state.now) }
    val ongoing = matches.filter { it.ongoing(state.now) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        status(vm, state)
        item {
            DiscoverFilterControls(vm, state, filtersExpanded, toggleFilters)
            Text("${matches.size} events", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        if (state.loading && state.snapshot.eventsUpdated == null) item { LoadingContent("Loading events…") }
        else if (matches.isEmpty()) item { EmptyContent("No matching events", "Try another date, search, or category.", "Reset filters") { vm.resetEvents(); vm.filter { it.copy(eventQuery = "", date = DiscoverDate.UPCOMING) } } }
        if (regular.isNotEmpty()) item { Heading("Events") }
        items(regular, key = { it.id }) { event -> EventRow(event, event.id in state.saved.events, { open(DiscoverRoute("event", event.id)) }) }
        if (ongoing.isNotEmpty()) item { Heading("Ongoing on campus") }
        items(ongoing, key = { it.id }) { event -> EventRow(event, event.id in state.saved.events, { open(DiscoverRoute("event", event.id)) }) }
    }
}

@Composable
private fun ClubList(vm: DiscoverViewModel, state: DiscoverUiState, open: (DiscoverRoute) -> Unit) {
    val clubs = vm.clubs(state)
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        status(vm, state)
        item {
            DiscoverFilterControls(vm, state, expanded = false, toggleExpanded = {}, clubs = true)
            Heading("Clubs · ${clubs.size}")
        }
        if (state.loading && state.snapshot.organizationsUpdated == null) item { LoadingContent("Loading clubs…") }
        else if (clubs.isEmpty()) item { EmptyContent("No matching clubs", "Try another interest or browse every category.", "Show all clubs") { vm.filter { it.copy(clubQuery = "", clubCategory = "") } } }
        items(clubs, key = { it.id }) { club -> ClubRow(club, club.id in state.saved.organizations, { open(DiscoverRoute("club", club.id)) }) }
    }
}

@Composable
private fun SavedList(vm: DiscoverViewModel, state: DiscoverUiState, open: (DiscoverRoute) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        status(vm, state)
        if (state.loading && !state.canSave && !state.loaded) item { LoadingContent("Loading saved items…") }
        else if (state.saved.organizations.isEmpty() && state.saved.events.isEmpty()) item {
            EmptyContent("Plans worth keeping", "Save a club or event to find it here, even offline.", "Explore events") { vm.prepareEvents(); open(DiscoverRoute("events")) }
            TextButton(onClick = { open(DiscoverRoute("clubs")) }) { Text("Find a club") }
        }
        if (state.savedClubs.isNotEmpty()) item { Heading("Clubs") }
        items(state.savedClubs, key = { "club-${it.id}" }) { club -> ClubRow(club, true, { open(DiscoverRoute("club", club.id)) }, { vm.toggle(club) }, state.canSave && !state.saving) }
        if (state.savedUpcoming.isNotEmpty()) item { Heading("Upcoming events") }
        items(state.savedUpcoming, key = { "upcoming-${it.id}" }) { event -> EventRow(event, true, { open(DiscoverRoute("event", event.id)) }, { vm.toggle(event) }, state.canSave && !state.saving) }
        if (state.savedPast.isNotEmpty()) item { Heading("Past events") }
        items(state.savedPast, key = { "past-${it.id}" }) { event -> EventRow(event, true, { open(DiscoverRoute("event", event.id)) }, { vm.toggle(event) }, state.canSave && !state.saving) }
    }
}

private fun LazyListScope.status(vm: DiscoverViewModel, state: DiscoverUiState) {
    val limited = !state.snapshot.directoryComplete && state.snapshot.organizationsUpdated != null
    if (state.issues.isEmpty() && state.saveError == null && !limited) return
    item(key = "status") {
        Column(modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            state.issues.forEach { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            state.saveError?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
            if (!state.snapshot.directoryComplete && state.snapshot.organizationsUpdated != null && state.issues.none { it.startsWith("Limited club") }) Text("Limited directory. Some clubs and events may be missing.", style = MaterialTheme.typography.bodySmall)
            if (state.issues.isNotEmpty() || state.saveError != null) {
                state.snapshot.eventsUpdated?.let { Text("Events last updated ${Instant.ofEpochMilli(it).atZone(DiscoverSource.zone).format(DateTimeFormatter.ofPattern("MMM d, h:mm a"))}", style = MaterialTheme.typography.labelSmall) }
                TextButton(onClick = { vm.refresh(true) }, enabled = !state.loading) { Text("Try again") }
            }
        }
    }
}

@Composable private fun Heading(text: String) { Text(text, Modifier.padding(top = 8.dp, bottom = 8.dp).semantics { heading() }, style = MaterialTheme.typography.titleMedium) }
@Composable private fun LoadingContent(text: String) { Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) { LoadingIndicator(); Spacer(Modifier.height(16.dp)); Text(text) } }
@Composable private fun MissingDetail(loading: Boolean) { if (loading) LoadingContent("Loading details…") else Text("This item is no longer available. Saved items remain accessible in Saved.", Modifier.padding(24.dp)) }
@Composable private fun EmptyContent(title: String, message: String, action: String, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = onClick) { Text(action) }
    }
}

@Composable
private fun SaveButton(saved: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    val scale by animateFloatAsState(if (saved) 1.08f else 1f, spring(dampingRatio = 1f, stiffness = 500f), label = "bookmark")
    IconToggleButton(checked = saved, onCheckedChange = { onClick() }, enabled = enabled) {
        Icon(if (saved) DiscoverSymbols.BookmarkFilled else DiscoverSymbols.Bookmark, if (saved) "Remove from saved" else "Save",
            Modifier.graphicsLayer { scaleX = scale; scaleY = scale }, tint = if (!enabled) MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f) else if (saved) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
@Composable
private fun Thumbnail(url: String?, fallback: ImageVector, size: Int = 56) {
    var failed by remember(url) { mutableStateOf(false) }
    Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.secondaryContainer, modifier = Modifier.size(size.dp)) {
        if (url != null && !failed) AsyncImage(url, null, contentScale = ContentScale.Crop, onError = { failed = true })
        else Box(contentAlignment = Alignment.Center) { Icon(fallback, null, tint = MaterialTheme.colorScheme.onSecondaryContainer) }
    }
}
@Composable
private fun EventRow(event: CampusEvent, saved: Boolean, open: () -> Unit, unsave: (() -> Unit)? = null, saveEnabled: Boolean = true) {
    Surface(onClick = open, shape = MaterialTheme.shapes.medium, color = diningCellColor()) {
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (event.imageUrl != null || event.organizationImageUrl != null) Thumbnail(event.imageUrl ?: event.organizationImageUrl, DiningSymbols.CalendarMonth, 64)
            else Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.secondaryContainer, contentColor = MaterialTheme.colorScheme.onSecondaryContainer) {
                Column(Modifier.width(56.dp).padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(event.startTime.format(DateTimeFormatter.ofPattern("MMM")), style = MaterialTheme.typography.labelMedium)
                    Text(event.startTime.dayOfMonth.toString(), style = MaterialTheme.typography.headlineSmall)
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(event.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                EventMetadata(DiningSymbols.AccessTime, eventRowTime(event), eventTime(event))
                if (event.online || event.location.isNotBlank()) EventMetadata(
                    if (event.online) DiscoverSymbols.Online else DiscoverSymbols.Location,
                    if (event.online) "Online" else event.location,
                )
                if (event.hostNames.isNotEmpty()) EventMetadata(DiscoverSymbols.Groups, event.hostNames.joinToString(" · ") { it.removeSuffix(" at University Park") }, event.hostNames.joinToString(" · "))
                if (event.cancelled) Text("Cancelled", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.error)
                else BenefitBadges(event.benefits)

            }
            if (unsave != null) SaveButton(saved, saveEnabled, unsave)
            else if (saved) Icon(DiscoverSymbols.BookmarkFilled, "Saved", Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
            else Icon(DiningSymbols.ChevronRight, null, Modifier.size(20.dp))
        }
    }
}
@Composable
private fun ClubRow(club: CampusOrganization, saved: Boolean, open: () -> Unit, unsave: (() -> Unit)? = null, saveEnabled: Boolean = true) {
    Surface(onClick = open, shape = MaterialTheme.shapes.medium, color = diningCellColor()) {
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Thumbnail(club.imageUrl, DiscoverSymbols.Groups)
            Column(Modifier.weight(1f)) {
                Text(club.name, style = MaterialTheme.typography.titleSmall)
                if (club.summary.isNotBlank()) Text(club.summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            if (unsave != null) SaveButton(saved, saveEnabled, unsave)
            else if (saved) Icon(DiscoverSymbols.BookmarkFilled, "Saved", Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
            else Icon(DiningSymbols.ChevronRight, null, Modifier.size(20.dp))
        }
    }
}

@Composable
private fun ClubDetail(club: CampusOrganization, vm: DiscoverViewModel, state: DiscoverUiState, actions: DiscoverActions, open: (DiscoverRoute) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Thumbnail(club.imageUrl, DiscoverSymbols.Groups, 88)
                Text(club.name, Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
                if (club.categories.isNotEmpty()) Text(club.categories.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (club.officialUrl != null) item { Button(onClick = { actions.open(club.officialUrl) }) { Text("Visit official club page") } }
        val about = club.description.ifBlank { club.summary }
        if (about.isNotBlank()) item { Column { Heading("About"); SelectionContainer { Text(about, style = MaterialTheme.typography.bodyLarge) } } }
        item { Heading("Upcoming events") }
        val events = state.clubEvents(club.id)
        if (events.isEmpty()) item { Text("No upcoming events listed.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        items(events, key = { it.id }) { event -> EventRow(event, event.id in state.saved.events, { open(DiscoverRoute("event", event.id)) }) }
        status(vm, state)
    }
}

@Composable
private fun EventDetail(event: CampusEvent, vm: DiscoverViewModel, state: DiscoverUiState, actions: DiscoverActions, open: (DiscoverRoute) -> Unit) {
    val hosts = event.organizationIds.mapNotNull(state::club).distinctBy { DiscoverSource.normalized(it.name) }
    val hostNames = hosts.map { DiscoverSource.normalized(it.name) }.toSet()
    val unmatchedHosts = event.hostNames.distinctBy(DiscoverSource::normalized).filterNot { DiscoverSource.normalized(it) in hostNames }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
        if (event.imageUrl != null) item {
            var ratio by remember(event.imageUrl) { mutableFloatStateOf(1f) }
            var failed by remember(event.imageUrl) { mutableStateOf(false) }
            if (!failed) AsyncImage(event.imageUrl, "${event.title} event artwork",
                Modifier.fillMaxWidth().heightIn(max = 480.dp).aspectRatio(ratio).clip(MaterialTheme.shapes.large), contentScale = ContentScale.Fit,
                onSuccess = { result -> val size = result.painter.intrinsicSize; if (size.width > 0 && size.height > 0) ratio = size.width / size.height },
                onError = { failed = true })
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (event.cancelled) Text("Cancelled", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.labelLarge)
                Text(event.title, Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
                BenefitBadges(event.benefits)
            }
        }
        item {
            Surface(shape = MaterialTheme.shapes.large, color = diningCellColor()) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { Icon(DiningSymbols.CalendarMonth, null, tint = discoverIconColor(DiningSymbols.CalendarMonth)); Text(eventTime(event), style = MaterialTheme.typography.bodyLarge) }
                    if (event.online) {
                        HorizontalDivider()
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { Icon(DiscoverSymbols.Online, null, tint = discoverIconColor(DiscoverSymbols.Online)); Text("Online") }
                        if (event.onlineUrl != null && !event.cancelled) Button(onClick = { actions.open(event.onlineUrl) }) { Text("Open online event") }
                        else if (event.officialUrl != null) TextButton(onClick = { actions.open(event.officialUrl) }) { Text("View online details in Discover") }
                    } else if (event.location.isNotBlank()) {
                        HorizontalDivider()
                        Row(Modifier.fillMaxWidth().clickable { actions.directions(event) }.heightIn(min = 48.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(DiscoverSymbols.Location, null, tint = discoverIconColor(DiscoverSymbols.Location))
                            Column(Modifier.weight(1f)) { Text(event.location); Text("Get directions", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary) }
                            Icon(DiningSymbols.ChevronRight, null)
                        }
                    }
                }
            }
        }
        if (hosts.isNotEmpty() || unmatchedHosts.isNotEmpty()) item { Heading("Hosted by") }
        items(hosts, key = { "host-${it.id}" }) { club -> ClubRow(club, club.id in state.saved.organizations, { open(DiscoverRoute("club", club.id)) }) }
        items(unmatchedHosts, key = { "host-name-$it" }) { name -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { Thumbnail(event.organizationImageUrl, DiscoverSymbols.Groups, 48); Text(name, style = MaterialTheme.typography.bodyLarge) } }
        if (event.description.isNotBlank()) item { Column { Heading("About"); SelectionContainer { Text(event.description, style = MaterialTheme.typography.bodyLarge) } } }
        status(vm, state)
    }
}

@Composable
private fun EventMetadata(icon: ImageVector, text: String, spokenText: String = text) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.clearAndSetSemantics { contentDescription = spokenText }) {
        Icon(icon, null, Modifier.size(16.dp), tint = discoverIconColor(icon))
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun BenefitBadges(benefits: List<String>) {
    if (benefits.isEmpty()) return
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        benefits.distinct().forEach { benefit ->
            Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.secondaryContainer,
                contentColor = MaterialTheme.colorScheme.onSecondaryContainer) {
                Row(Modifier.padding(horizontal = 6.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(benefit, style = MaterialTheme.typography.labelSmall)
                }
            }
        }
    }
}
