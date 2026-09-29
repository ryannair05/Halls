package com.ryannair05.meetandeat

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.lerp
import androidx.compose.foundation.Image
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ryannair05.meetandeat.dining.*

internal object DiningSpacing {
    val page = 24.dp
    val gap = 8.dp
    val section = 24.dp
}

@Composable
private fun Modifier.diningPressFeedback(interactions: MutableInteractionSource): Modifier {
    val pressed by interactions.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.99f else 1f,
        animationSpec = spring(dampingRatio = 1f, stiffness = 700f), label = "row press")
    return graphicsLayer { scaleX = scale; scaleY = scale }
}

@Composable
internal fun diningHeaderColor() = lerp(
    MaterialTheme.colorScheme.surfaceContainerLow, MaterialTheme.colorScheme.secondaryContainer, 0.35f)

@Composable
internal fun diningSearchColor(): androidx.compose.ui.graphics.Color {
    val colors = MaterialTheme.colorScheme
    return if (colors == HallsLightColors || colors == HallsDarkColors) {
        lerp(colors.surfaceContainerHigh, colors.primaryContainer, 0.65f)
    } else colors.surfaceContainerHigh
}

@Composable
private fun diningHallColor() = lerp(
    MaterialTheme.colorScheme.surfaceContainerLow, MaterialTheme.colorScheme.primaryContainer, 0.55f)

@Composable
internal fun diningCellColor() = lerp(
    MaterialTheme.colorScheme.surfaceContainerLow, MaterialTheme.colorScheme.primaryContainer, 0.2f)

@Composable
internal fun DiningShortcutIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, discover: Boolean = false) {
    val colors = MaterialTheme.colorScheme
    Surface(
        shape = MaterialTheme.shapes.medium,
        color = if (discover) colors.secondaryContainer else colors.tertiaryContainer,
        contentColor = if (discover) colors.onSecondaryContainer else colors.onTertiaryContainer,
    ) {
        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) { Icon(icon, null, Modifier.size(24.dp)) }
    }
}

@Composable
internal fun SectionHeader(title: String, modifier: Modifier = Modifier, topPadding: Dp = 16.dp) {
    Text(title, modifier.semantics { heading() }.padding(top = topPadding, bottom = 8.dp),
        style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
internal fun DiningHallRow(hall: PSUDiningHall, hours: String, onClick: () -> Unit,
    onOfficialMenu: () -> Unit, onMaps: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val interactions = remember { MutableInteractionSource() }
    Row(Modifier.fillMaxWidth().diningPressFeedback(interactions)
        .background(diningHallColor()).combinedClickable(
        interactionSource = interactions, indication = LocalIndication.current, role = Role.Button, onClick = onClick,
        onLongClick = { expanded = true }, onLongClickLabel = "Dining hall options")
        .heightIn(min = 88.dp).padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Image(painterResource(hall.imageRes), null, contentScale = ContentScale.Crop,
            modifier = Modifier.size(64.dp).clip(MaterialTheme.shapes.medium))
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(hall.displayName, style = MaterialTheme.typography.titleMedium)
            Text(hours, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Box {
            IconButton(onClick = { expanded = true }) { Icon(DiningSymbols.MoreVert, "${hall.displayName} options") }
            DropdownMenu(expanded, { expanded = false }) {
                DropdownMenuItem({ Text("Official menu") }, { expanded = false; onOfficialMenu() })
                DropdownMenuItem({ Text("Open in Maps") }, { expanded = false; onMaps() })
            }
        }
        Icon(DiningSymbols.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(24.dp))
    }
}

@Composable
internal fun MenuFoodRow(item: DiningMenuItem, onClick: () -> Unit, supportingText: String? = null) {
    val interactions = remember { MutableInteractionSource() }
    Column {
        Row(Modifier.fillMaxWidth().diningPressFeedback(interactions)
            .background(diningCellColor()).clickable(
            interactionSource = interactions, indication = LocalIndication.current, role = Role.Button, onClick = onClick)
            .heightIn(min = 56.dp).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(item.name, style = MaterialTheme.typography.bodyLarge)
                supportingText?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            Spacer(Modifier.width(8.dp))
            Box(Modifier.widthIn(max = 104.dp)) { TraitText(item) }
            Spacer(Modifier.width(8.dp))
            Icon(DiningSymbols.ChevronRight, null, Modifier.size(24.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    }
}

@Composable
internal fun AllergenChip(trait: MenuTrait) {
    // Informational chip: no fake click action or disabled semantics.
    Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Row(Modifier.padding(horizontal = 8.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MenuTraitIcon(trait, Modifier.size(20.dp))
            Text(trait.displayName, style = MaterialTheme.typography.labelLarge)
        }
    }
}

@Composable
internal fun MacroSummary(facts: List<NutritionFact>) {
    val normalized = facts.associateBy { normalizeDiningText(it.name) }
    val macros = listOf("calories" to "Calories", "total fat" to "Fat", "total carbohydrate" to "Carbs", "protein" to "Protein")
    Surface(shape = MaterialTheme.shapes.extraLarge, color = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer) {
        BoxWithConstraints(Modifier.fillMaxWidth().padding(16.dp)) {
            val fontScale = androidx.compose.ui.platform.LocalDensity.current.fontScale
            val columns = if (maxWidth < 300.dp || fontScale > 1.3f) 2 else 4
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                macros.chunked(columns).forEach { group ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        group.forEach { (key, label) ->
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(normalized[key]?.value?.substringBefore(" · ") ?: "—", style = MaterialTheme.typography.headlineSmall)
                                Text(label, style = MaterialTheme.typography.labelMedium)
                            }
                        }
                    }
                }
            }
        }
    }
}
