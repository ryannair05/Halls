package com.ryannair05.meetandeat.cata

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun StopSheet(stop: StopInfo, vm: MapVM, modifier: Modifier = Modifier) {
    com.ryannair05.meetandeat.TrackScreen("bus_stop")
    val routes by vm.routes.collectAsState()
    val selected by vm.selected.collectAsState()
    val trackedRouteIds = remember(routes, selected) {
        routes.filter { it.kml in selected }.map { it.routeId }.toSet()
    }
    val departures by vm.deps.collectAsState()
    val loading by vm.loadingDepartures.collectAsState()
    val error by vm.departureError.collectAsState()
    Column(modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(stop.name, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.LocationOn, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.width(4.dp))
                    Text(
                        buildString {
                            append("Stop #${stop.id}")
                            stop.distanceMiles?.let { append(" · %.1f miles away".format(it)) }
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            IconButton(onClick = vm::refreshDepartures) { Icon(Icons.Default.Refresh, "Refresh departures") }
        }
        val routeDepartures = departures.distinctBy(DepartureUi::route)
        if (routeDepartures.isNotEmpty()) {
            FlowRow(
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                routeDepartures.forEach { departure ->
                    RouteBadge(
                        departure.routeAbbreviation, departure.color, departure.textColor,
                        fontWeight = if (departure.route in trackedRouteIds) FontWeight.Bold else FontWeight.Normal,
                    )
                }
            }
        }
        HorizontalDivider(Modifier.padding(vertical = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)
        Text("Upcoming departures", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        if (loading && departures.isEmpty()) {
            Box(Modifier.fillMaxWidth().height(140.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        } else if (error != null && departures.isEmpty()) {
            Box(Modifier.fillMaxWidth().height(150.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Default.CloudOff, null, tint = MaterialTheme.colorScheme.error)
                    Text(error.orEmpty(), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    TextButton(onClick = vm::refreshDepartures) { Text("Try again") }
                }
            }
        } else if (departures.isEmpty()) {
            Box(Modifier.fillMaxWidth().height(140.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Default.EventBusy, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.secondary)
                    Text("No upcoming departures", style = MaterialTheme.typography.titleMedium)
                    Text("Pull down or tap refresh to check again.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else {
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            LazyColumn(
                Modifier.fillMaxWidth().weight(1f),
                contentPadding = PaddingValues(vertical = 8.dp),
            ) {
                items(departures, key = { "${it.route}-${it.etaSort}-${it.dest}" }) { departure ->
                    ListItem(
                        modifier = Modifier,
                        leadingContent = {
                            RouteBadge(
                                departure.routeAbbreviation, departure.color, departure.textColor,
                                fontWeight = if (departure.route in trackedRouteIds) FontWeight.Bold else FontWeight.Normal,
                            )
                        },
                        trailingContent = {
                                                Text(
                                                    departure.etaText,
                                                    style = MaterialTheme.typography.titleMedium,
                                                    fontWeight = FontWeight.Bold,
                                                    color = if (departure.isLate) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                                                )
                                            },
                        overlineContent = null,
                        supportingContent = { Text(departure.dest, color = MaterialTheme.colorScheme.onSurfaceVariant) },
                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                        elevation = ListItemDefaults.elevation(),
                        content = { Text(departure.routeLongName, fontWeight = if (departure.route in trackedRouteIds) FontWeight.Bold else FontWeight.Normal) },
                    )
                }
            }
        }
        Text(
            "Times are approximate and subject to change",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(vertical = 12.dp),
        )
    }
}

@Composable
fun BusSheet(bus: BusInfo, route: RouteModel?) {
    com.ryannair05.meetandeat.TrackScreen("bus_details")
    val ratio = if (bus.capacity > 0) bus.onBoard.toFloat() / bus.capacity else 0f
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            RouteBadge(
                route?.abbr ?: bus.routeId.toString(),
                bus.routeColor,
                route?.textColor.toClr(),
                RouteBadgeSize.Regular,
            )
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(route?.longName ?: "Route ${bus.routeId}", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                Text(bus.dest ?: "Destination unavailable", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Spacer(Modifier.height(20.dp))
        Surface(shape = MaterialTheme.shapes.extraLarge, color = MaterialTheme.colorScheme.surfaceContainerHigh) {
            Column(Modifier.fillMaxWidth().padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Groups, null, tint = bus.statusColor)
                    Spacer(Modifier.width(8.dp))
                    Text("Passenger load", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.weight(1f))
                    Text("${bus.onBoard} / ${bus.capacity}", fontWeight = FontWeight.Bold)
                }
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(
                    progress = { ratio.coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth().height(8.dp),
                    color = bus.statusColor,
                    trackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                )
                Text(
                    when { ratio >= .9f -> "Very full"; ratio >= .5f -> "Moderate occupancy"; else -> "Seats likely available" },
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}
