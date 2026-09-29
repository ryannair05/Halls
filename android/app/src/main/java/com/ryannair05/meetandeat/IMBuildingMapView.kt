package com.ryannair05.meetandeat

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

internal data class IMFacilityRegion(val facility: String, val court: Int? = null) {
    val label: String get() = facility + (court?.let { " · Court $it" } ?: "")

    companion object {
        fun regions(location: String): Set<IMFacilityRegion> {
            val text = location.lowercase().replace('–', '-').replace('—', '-')
            val gym = Regex("gym\\s*([1-4])\\b").find(text)?.groupValues?.get(1)?.toInt()
            val facility = when {
                gym != null -> "Gym $gym"
                "mac court" in text -> "Gym 2"
                "racquetball" in text -> "Racquetball"
                "turf" in text || "east" in text || "west" in text -> return buildSet {
                    if ("west" in text || "east" !in text) add(IMFacilityRegion("Turf West"))
                    if ("east" in text || "west" !in text) add(IMFacilityRegion("Turf East"))
                }
                else -> return emptySet()
            }
            if (facility == "Gym 2") return setOf(IMFacilityRegion(facility))
            val maxCourt = if (facility == "Racquetball") 10 else 3
            val specification = Regex("courts?\\s+([0-9][0-9 ,&-]*(?:(?:and|to)\\s*[0-9]+)?)")
                .find(text)?.groupValues?.get(1)
            val courts = if (specification == null) (1..maxCourt).toSet() else buildSet {
                Regex("(\\d+)\\s*(?:-|to)\\s*(\\d+)|(\\d+)").findAll(specification).forEach { match ->
                    if (match.groupValues[3].isNotEmpty()) add(match.groupValues[3].toInt())
                    else addAll(match.groupValues[1].toInt()..match.groupValues[2].toInt())
                }
            }
            return courts.filter { it in 1..maxCourt }.map { IMFacilityRegion(facility, it) }.toSet()
        }
    }
}

private val gymColor = Color(0xFFFAF2D1)
private val racquetColor = Color(0xFF73C4FA)
private val turfColor = Color(0xFF87F087)
private val greyColor = Color(0xFFD9DBDE)
private val studioColor = Color(0xFFFFA640)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BuildingMapSection(schedules: List<ActivitySchedule>) {
    val active = remember(schedules) {
        schedules.flatMap { it.tables }.flatMap { it.rows }
            .flatMap { IMFacilityRegion.regions(it.cells.firstOrNull().orEmpty()) }.toSet()
    }
    var enlarged by rememberSaveable { mutableStateOf(false) }
    var selectedLabel by rememberSaveable { mutableStateOf<String?>(null) }
    val selected = active.firstOrNull { it.label == selectedLabel }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Building Map", Modifier.weight(1f), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
            TextButton(onClick = { enlarged = !enlarged }) { Text(if (enlarged) "Fit map" else "Enlarge") }
        }
        Text(if (enlarged) "Swipe to explore. Tap a highlighted court for schedules."
            else "Intramural Building · Tap a highlighted court for schedules.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(shape = MaterialTheme.shapes.large, color = Color.White) {
            // Preserve the iOS floor plan proportions while keeping court targets usable on phones.
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val mapWidth = maxOf(maxWidth, 640.dp)
                val density = LocalDensity.current
                val scale = if (enlarged) 1f else (maxWidth / mapWidth).coerceAtMost(1f)
                CompositionLocalProvider(LocalDensity provides Density(density.density * scale, density.fontScale)) {
                    Row(Modifier.horizontalScroll(rememberScrollState())) {
                        Column(Modifier.width(mapWidth).height(mapWidth / 1.3f).padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Row(Modifier.weight(.30f), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.Bottom) {
                                Column(Modifier.weight(.08f).fillMaxHeight(.65f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    MapRoom("114A\nStorage", greyColor, Modifier.weight(1f))
                                    MapRoom("114B\nStorage", greyColor, Modifier.weight(1f))
                                }
                                MapFacility("GYM 4 (114)", "Gym 4", gymColor, listOf(1, 2, 3), active, { selectedLabel = it.label }, Modifier.weight(.38f), horizontal = true)
                                Column(Modifier.weight(.50f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    MapFacility("Indoor Turf Field (140)", "Turf", turfColor, emptyList(), active, { selectedLabel = it.label }, Modifier.weight(.78f), horizontal = true)
                                    Row(Modifier.weight(.22f), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                                        MapRoom("Bouldering", Color(0xFF73E073), Modifier.weight(4f))
                                        MapRoom("139\nClimbing", Color(0xFF73E073), Modifier.weight(1f))
                                    }
                                }
                            }
                            Row(Modifier.weight(.46f), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                                MapFacility("GYM 1 (122)", "Gym 1", gymColor, listOf(3, 2, 1), active, { selectedLabel = it.label }, Modifier.weight(.18f))
                                Column(Modifier.weight(.08f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    MapFacility("Racquetball", "Racquetball", racquetColor, (10 downTo 6).toList(), active, { selectedLabel = it.label }, Modifier.weight(.84f))
                                    MapRoom("129\nEquip RM", Color(0xFFFA1AA6), Modifier.weight(.16f))
                                }
                                Column(Modifier.weight(.20f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    MapRoom("115A Storage", greyColor, Modifier.height(20.dp))
                                    MapFacility("GYM 2\nMAC Court (115)", "Gym 2", gymColor, emptyList(), active, { selectedLabel = it.label }, Modifier.weight(1f))
                                }
                                MapFacility("Racquetball", "Racquetball", racquetColor, (5 downTo 1).toList(), active, { selectedLabel = it.label }, Modifier.weight(.08f))
                                MapFacility("GYM 3 (105)", "Gym 3", gymColor, listOf(3, 2, 1), active, { selectedLabel = it.label }, Modifier.weight(.14f))
                                Column(Modifier.weight(.16f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                                        MapRoom("130\nClub\nSports", greyColor, Modifier.weight(1f))
                                        MapRoom("138\nWellness\nStudio", studioColor, Modifier.weight(1f))
                                    }
                                    Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                                        MapRoom("Squash", Color(0xFFFA99A8), Modifier.weight(1f))
                                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                            MapRoom("REST\nROOMS", greyColor, Modifier.weight(1f))
                                            MapRoom("135\nNittany\nRoom", greyColor, Modifier.weight(1f))
                                        }
                                    }
                                }
                            }
                            Row(Modifier.weight(.16f), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                                MapRoom("124/125\nFitness Studios", studioColor, Modifier.weight(.18f))
                                Column(Modifier.weight(.08f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    MapRoom("127", greyColor, Modifier.weight(1f))
                                    MapRoom("W    M", Color(0xFFFAF233), Modifier.weight(1f))
                                }
                                Column(Modifier.weight(.22f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    MapRoom("ELEVATOR", greyColor, Modifier.weight(.35f))
                                    MapRoom("101\nCampus Rec Admin", greyColor, Modifier.weight(.65f))
                                }
                                Column(Modifier.weight(.10f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    MapRoom("Front Desk", greyColor, Modifier.weight(.35f))
                                    MapRoom("LOBBY", Color.White, Modifier.weight(.65f))
                                }
                                MapRoom("↑\nENTRY\n& EXIT", Color(0xFFF21A1A), Modifier.weight(.06f), Color.White)
                                MapRoom("103\nFitness Center", Color(0xFF00F2F2), Modifier.weight(.30f))
                            }
                        }
                    }
                }
            }
        }
        if (active.isEmpty()) Text("No facility schedules for the next seven days.", style = MaterialTheme.typography.bodyMedium)
    }
    if (selected != null) {
        ModalBottomSheet(onDismissRequest = { selectedLabel = null }) {
            LazyColumn(Modifier.fillMaxWidth(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                item {
                    Text(selected.label, style = MaterialTheme.typography.headlineSmall)
                    Text("Current Schedules", style = MaterialTheme.typography.titleMedium)
                }
                schedules.forEach { schedule ->
                    val tables = schedule.tables.mapNotNull { table ->
                        val rows = table.rows.filter { selected in IMFacilityRegion.regions(it.cells.firstOrNull().orEmpty()) }
                        if (rows.isEmpty()) null else table.copy(rows = rows)
                    }
                    if (tables.isNotEmpty()) item(key = schedule.id) {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(schedule.activity, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                            tables.forEach { ScheduleTableDisplay(it) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MapRoom(label: String, color: Color, modifier: Modifier, textColor: Color = Color.Black) {
    Surface(modifier.fillMaxSize(), color = color, shape = RoundedCornerShape(2.dp), border = BorderStroke(.5.dp, Color.Black.copy(.4f))) {
        Box(contentAlignment = Alignment.Center) {
            Text(label, Modifier.padding(2.dp), color = textColor, fontSize = 9.sp, lineHeight = 10.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun MapFacility(title: String, facility: String, color: Color, courts: List<Int>, active: Set<IMFacilityRegion>, onSelect: (IMFacilityRegion) -> Unit, modifier: Modifier, horizontal: Boolean = false) {
    val regions = when {
        facility == "Turf" -> listOf(IMFacilityRegion("Turf West"), IMFacilityRegion("Turf East"))
        courts.isEmpty() -> listOf(IMFacilityRegion(facility))
        else -> courts.map { IMFacilityRegion(facility, it) }
    }
    Surface(modifier.fillMaxHeight(), color = color, shape = RoundedCornerShape(3.dp), border = BorderStroke(.5.dp, Color.Black.copy(.4f))) {
        Column(Modifier.padding(3.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, color = Color.Black, fontSize = 10.sp, lineHeight = 11.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
            if (horizontal) Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                regions.forEach { Court(it, it in active, onSelect, Modifier.weight(1f).fillMaxHeight()) }
            } else Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                regions.forEach { Court(it, it in active, onSelect, Modifier.weight(1f).fillMaxWidth()) }
            }
        }
    }
}

@Composable
private fun Court(region: IMFacilityRegion, active: Boolean, onSelect: (IMFacilityRegion) -> Unit, modifier: Modifier) {
    val blue = Color(0xFF1565C0)
    Surface(onClick = { onSelect(region) }, enabled = active, modifier = modifier.semantics {
        contentDescription = "${region.label}, ${if (active) "view schedules" else "no schedules"}"
    }, shape = RoundedCornerShape(2.dp), color = if (active) blue.copy(.15f) else Color.Transparent,
        border = BorderStroke(if (active) 3.dp else .5.dp, if (active) blue else Color.Black.copy(.2f))) {
        Box(contentAlignment = Alignment.Center) {
            Text(region.court?.let { if (region.facility == "Racquetball") "$it" else "Ct $it" }
                ?: region.facility.removePrefix("Turf ").replace("Gym 2", "MAC"),
                color = if (active) Color(0xFF0D47A1) else Color.DarkGray, fontSize = 10.sp, textAlign = TextAlign.Center)
        }
    }
}
