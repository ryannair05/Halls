package com.ryannair05.meetandeat.cata

import android.graphics.Color as AndroidColor
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RoutePickerSheet(vm: MapVM, onDismiss: () -> Unit) {
    com.ryannair05.meetandeat.TrackScreen("bus_routes")
    val routes by vm.routes.collectAsState()
    val selected by vm.selected.collectAsState()
    val loading by vm.routeLoading.collectAsState()
    val error by vm.routeError.collectAsState()
    var query by remember { mutableStateOf("") }
    val visibleRoutes = remember(routes, query) {
        routes.filter { query.isBlank() || it.longName.contains(query, true) || it.abbr.contains(query, true) }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surfaceContainerLow) {
        RoutePickerContent(
            routes = visibleRoutes,
            selected = selected,
            loading = loading,
            error = error,
            query = query,
            onQuery = { query = it },
            onToggle = vm::toggle,
            onRetry = vm::refreshRoutes,
            onDismiss = onDismiss,
        )
    }
}

@Composable
internal fun RoutePickerContent(
    routes: List<RouteModel>,
    selected: Set<String>,
    loading: Boolean,
    error: String?,
    query: String,
    onQuery: (String) -> Unit,
    onToggle: (String) -> Unit,
    onRetry: () -> Unit,
    onDismiss: (() -> Unit)? = null,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Available routes", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                Text("Choose the lines shown on the map", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            onDismiss?.let { IconButton(onClick = it) { Icon(Icons.Default.Close, "Close") } }
        }
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = query,
            onValueChange = onQuery,
            modifier = Modifier.fillMaxWidth(),
            shape = MaterialTheme.shapes.extraLarge,
            singleLine = true,
            leadingIcon = { Icon(Icons.Default.Search, null) },
            trailingIcon = if (query.isNotEmpty()) ({ IconButton(onClick = { onQuery("") }) { Icon(Icons.Default.Clear, "Clear") } }) else null,
            placeholder = { Text("Find a route") },
        )
        if (loading) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 8.dp))
        error?.let {
            Surface(
                color = if (routes.isEmpty()) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.tertiaryContainer,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            ) { Text(it, Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium) }
        }
        if (!loading && routes.isEmpty()) {
            Box(Modifier.fillMaxWidth().height(220.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Default.Route, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.secondary)
                    Text("No routes found", style = MaterialTheme.typography.titleLarge)
                    TextButton(onClick = onRetry) { Text("Try again") }
                }
            }
        } else LazyColumn(Modifier.heightIn(max = 520.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
            items(routes, key = RouteModel::routeId) { route ->
                val isSelected = route.kml in selected
                ListItem(
                    modifier = Modifier.fillMaxWidth().clickable { onToggle(route.kml) },
                    supportingContent = { Text(route.abbr) },
                    leadingContent = {
                        RouteBadge(
                            route.abbr,
                            route.color.toClr(AndroidColor.BLUE),
                            route.textColor.toClr(),
                            RouteBadgeSize.Regular,
                        )
                    },
                    trailingContent = {
                        Icon(if (isSelected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked, if (isSelected) "Selected" else "Not selected", tint = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                ) { Text(route.longName, fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal) }
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
internal fun RouteBadge(
    abbreviation: String,
    background: Int,
    preferredText: Int = AndroidColor.TRANSPARENT,
    size: RouteBadgeSize = RouteBadgeSize.Compact,
    fontWeight: FontWeight = FontWeight.Bold,
) {
    val bg = Color(background)
    val text = remember(background, preferredText) {
        val preferred = if (preferredText == AndroidColor.TRANSPARENT) null else preferredText
        val foreground = preferred?.takeIf { contrastRatio(background, it) >= 4.5 }
            ?: if (contrastRatio(background, AndroidColor.BLACK) >= contrastRatio(background, AndroidColor.WHITE)) {
                AndroidColor.BLACK
            } else AndroidColor.WHITE
        Color(foreground)
    }
    val minimumHeight = if (size == RouteBadgeSize.Compact) 24.dp else 30.dp
    val horizontalPadding = if (size == RouteBadgeSize.Compact) 7.dp else 9.dp
    val verticalPadding = if (size == RouteBadgeSize.Compact) 3.dp else 5.dp
    val typography = if (size == RouteBadgeSize.Compact) MaterialTheme.typography.labelMedium else MaterialTheme.typography.labelLarge
    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = bg,
        contentColor = text,
        modifier = Modifier.heightIn(min = minimumHeight).widthIn(min = minimumHeight, max = 88.dp),
    ) {
        Box(Modifier.padding(horizontal = horizontalPadding, vertical = verticalPadding), contentAlignment = Alignment.Center) {
            Text(abbreviation.ifBlank { "—" }, style = typography, fontWeight = fontWeight, maxLines = 1)
        }
    }
}

internal enum class RouteBadgeSize { Compact, Regular }

internal fun contrastRatio(background: Int, foreground: Int): Double {
    if (foreground == AndroidColor.TRANSPARENT) return 0.0
    fun luminance(color: Int): Double {
        fun channel(component: Int): Double {
            val srgb = component / 255.0
            return if (srgb <= .04045) srgb / 12.92 else Math.pow((srgb + .055) / 1.055, 2.4)
        }
        return .2126 * channel((color ushr 16) and 0xFF) +
            .7152 * channel((color ushr 8) and 0xFF) +
            .0722 * channel(color and 0xFF)
    }
    val first = luminance(background)
    val second = luminance(foreground)
    return (maxOf(first, second) + .05) / (minOf(first, second) + .05)
}
