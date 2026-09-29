@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ryannair05.meetandeat.discover

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.spring
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ryannair05.meetandeat.DiningSymbols

/** Filters edit the visible list immediately; expansion never changes the navigation stack. */
@Composable
internal fun DiscoverFilterControls(
    vm: DiscoverViewModel,
    state: DiscoverUiState,
    expanded: Boolean,
    toggleExpanded: () -> Unit,
    home: Boolean = false,
    clubs: Boolean = false,
) {
    val filters = state.filters
    val date = if (home) filters.homeDate else filters.date
    val category = if (clubs) filters.clubCategory else filters.eventCategory
    val active = if (clubs) category.isNotEmpty() else filters.eventCategory.isNotEmpty() || filters.onlineOnly || filters.savedClubsOnly
    Column(Modifier.animateContentSize(spring(dampingRatio = 1f, stiffness = 550f)), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (clubs) CategoryMenu(category, state.clubCategories) { value -> vm.filter { it.copy(clubCategory = value) } }
                else {
                    DateMenu(date) { value -> vm.filter { if (home) it.copy(homeDate = value) else it.copy(date = value) } }
                    if (state.supportsPerks) FilterChip(
                        selected = filters.freeFood,
                        onClick = { vm.filter { it.copy(freeFood = !it.freeFood) } },
                        label = { Text("Free food") },
                    )
                }
            }
            if (!clubs) IconToggleButton(checked = expanded, onCheckedChange = { toggleExpanded() }) {
                BadgedBox(badge = { if (active) Badge() }) {
                    Icon(DiningSymbols.FilterList, if (expanded) "Hide filters" else "More filters",
                        tint = if (active || expanded) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        // Keep active refinements visible and removable even when the panel is closed.
        if (!clubs && !expanded && active) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (category.isNotEmpty()) RemovableFilter(category) { vm.filter { if (clubs) it.copy(clubCategory = "") else it.copy(eventCategory = "") } }
            if (!clubs && filters.onlineOnly) RemovableFilter("Online") { vm.filter { it.copy(onlineOnly = false) } }
            if (!clubs && filters.savedClubsOnly) RemovableFilter("Saved clubs") { vm.filter { it.copy(savedClubsOnly = false) } }
        }
        AnimatedVisibility(expanded && !clubs) {
            Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLow) {
                Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(filters.onlineOnly, { vm.filter { it.copy(onlineOnly = !it.onlineOnly) } }, { Text("Online") })
                        FilterChip(filters.savedClubsOnly, { vm.filter { it.copy(savedClubsOnly = !it.savedClubsOnly) } }, { Text("Saved clubs") })
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) { CategoryMenu(category, state.eventCategories) { value -> vm.filter { it.copy(eventCategory = value) } } }
                        TextButton(onClick = { vm.filter { it.resetEventFilters(home) } }) { Text("Reset") }
                    }
                }
            }
        }
    }
}

@Composable
private fun DateMenu(selected: DiscoverDate, change: (DiscoverDate) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        AssistChip(onClick = { expanded = true }, label = { Text(selected.label) })
        DropdownMenu(expanded, { expanded = false }) {
            DiscoverDate.entries.forEach { date -> DropdownMenuItem(
                text = { Text(date.label) }, onClick = { change(date); expanded = false },
                trailingIcon = { RadioButton(date == selected, null) },
            ) }
        }
    }
}

@Composable
private fun CategoryMenu(selected: String, categories: List<String>, change: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        AssistChip(onClick = { expanded = true }, label = { Text(selected.ifEmpty { "Category" }) })
        DropdownMenu(expanded, { expanded = false }, modifier = Modifier.heightIn(max = 320.dp)) {
            (listOf("") + categories).forEach { category -> DropdownMenuItem(
                text = { Text(category.ifEmpty { "All categories" }) },
                onClick = { change(category); expanded = false },
                trailingIcon = { RadioButton(category == selected, null) },
            ) }
        }
    }
}

@Composable
private fun RemovableFilter(label: String, remove: () -> Unit) {
    InputChip(selected = true, onClick = remove, label = { Text(label) },
        trailingIcon = { Icon(DiningSymbols.Close, "Remove $label filter", Modifier.size(16.dp)) })
}

internal fun DiscoverFilters.resetEventFilters(home: Boolean) = copy(
    homeDate = if (home) DiscoverDate.TODAY else homeDate,
    date = if (home) date else DiscoverDate.WEEK,
    eventCategory = "", freeFood = false, onlineOnly = false, savedClubsOnly = false,
)
internal fun DiscoverFilters.forEventBrowse() = copy(date = homeDate, eventQuery = "")
