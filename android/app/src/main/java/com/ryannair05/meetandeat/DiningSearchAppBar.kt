package com.ryannair05.meetandeat

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.RowScope
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import kotlinx.coroutines.launch

/** Keeps query ownership in the existing view model; expansion is presentation-only state. */
@Suppress("DEPRECATION") // String input preserves the existing synchronous query callbacks.
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
internal fun DiningSearchAppBar(
    state: SearchBarState,
    query: String,
    onQueryChange: (String) -> Unit,
    title: String,
    searchHint: String,
    scrollBehavior: SearchBarScrollBehavior? = null,
    navigationIcon: @Composable (() -> Unit)? = null,
    compact: Boolean = false,
    actions: @Composable RowScope.() -> Unit,
    results: @Composable ColumnScope.() -> Unit,
) {
    val scope = rememberCoroutineScope()
    val keyboard = LocalSoftwareKeyboardController.current
    val expanded = state.targetValue == SearchBarValue.Expanded
    val colors = SearchBarDefaults.colors(containerColor = diningSearchColor())
    val inputField: @Composable () -> Unit = {
        SearchBarDefaults.InputField(
            query = query,
            onQueryChange = onQueryChange,
            onSearch = { keyboard?.hide() },
            expanded = expanded,
            onExpandedChange = { open ->
                scope.launch { if (open) state.animateToExpanded() else state.animateToCollapsed() }
            },
            modifier = Modifier.semantics { contentDescription = searchHint },
            placeholder = { Text(if (expanded) searchHint else title, maxLines = 1) },
            leadingIcon = {
                if (expanded) IconButton(onClick = { scope.launch { state.animateToCollapsed() } }) {
                    Icon(DiningSymbols.ArrowBack, "Close search")
                } else Icon(DiningSymbols.Search, null)
            },
            trailingIcon = if (query.isNotEmpty()) ({
                IconButton(onClick = { onQueryChange("") }) { Icon(DiningSymbols.Close, "Clear search") }
            }) else null,
            colors = colors.inputFieldColors,
        )
    }
    if (compact) {
        TopAppBar(
            title = { Text(if (query.isBlank()) title else query, style = MaterialTheme.typography.titleMedium, maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis) },
            navigationIcon = { navigationIcon?.invoke() },
            actions = {
                IconButton(onClick = { scope.launch { state.animateToExpanded() } }) {
                    Icon(DiningSymbols.Search, searchHint, tint = MaterialTheme.colorScheme.primary)
                }
                actions()
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = diningHeaderColor()),
        )
    } else AppBarWithSearch(
        state = state,
        inputField = inputField,
        navigationIcon = navigationIcon,
        actions = actions,
        scrollBehavior = scrollBehavior,
        colors = SearchBarDefaults.appBarWithSearchColors(
            searchBarColors = colors,
            appBarContainerColor = diningHeaderColor(),
            scrolledAppBarContainerColor = diningHeaderColor(),
        ),
    )
    ExpandedFullScreenSearchBar(
        state = state,
        inputField = inputField,
        colors = SearchBarDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
        content = results,
    )
}
