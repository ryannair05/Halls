package com.ryannair05.meetandeat

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** One destination value owns both displayed content and selected navigation semantics. */
internal enum class AppDestination(@param:StringRes val label: Int) {
    MEALS(R.string.destination_meals), MY_MEALS(R.string.destination_my_meals),
    CATA(R.string.destination_cata), RECREATION(R.string.destination_recreation);

    @Composable
    fun icon(selected: Boolean): ImageVector = when (this) {
        MEALS -> if (selected) DiningSymbols.MenuBookFilled else DiningSymbols.MenuBook
        MY_MEALS -> DiningSymbols.Restaurant
        CATA -> if (selected) DiningSymbols.DirectionsBusFilled else DiningSymbols.DirectionsBus
        RECREATION -> DiningSymbols.DirectionsRun
    }
}

@Composable
private fun DestinationLabel(destination: AppDestination) {
    // Labels may wrap when needed, but selection never changes their geometry.
    Text(stringResource(destination.label), modifier = Modifier.clearAndSetSemantics { }, minLines = 1, maxLines = 2,
        overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
internal fun AppNavigationBar(selected: AppDestination, select: (AppDestination) -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(
        modifier = Modifier.widthIn(max = 480.dp).fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        color = colors.surfaceContainer,
        shadowElevation = 2.dp,
    ) {
        // Surface propagates its full-width minimum to its child. This Material alpha's
        // short bar also applies that minimum to EACH item, pushing siblings off-screen.
        // Keep the bounded available width but clear the child minimum before measurement.
        Box(Modifier.fillMaxWidth(), propagateMinConstraints = false) {
            ShortNavigationBar(containerColor = colors.surfaceContainer,
                windowInsets = WindowInsets(0, 0, 0, 0)) {
                AppDestination.entries.forEach { destination ->
                    val label = stringResource(destination.label)
                    ShortNavigationBarItem(
                        selected = selected == destination,
                        onClick = { if (selected != destination) select(destination) },
                        modifier = Modifier.semantics { contentDescription = label },
                        icon = { Icon(destination.icon(selected == destination), null, Modifier.size(24.dp)) },
                        label = { DestinationLabel(destination) },
                    )
                }
            }
        }
    }
}

@Composable
internal fun AppNavigationRail(selected: AppDestination, select: (AppDestination) -> Unit) {
    NavigationRail(
        modifier = Modifier.width(120.dp).fillMaxHeight()
            .verticalScroll(rememberScrollState()),
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
        windowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Vertical),
    ) {
        Spacer(Modifier.height(12.dp))
        AppDestination.entries.forEach { destination ->
            val label = stringResource(destination.label)
            NavigationRailItem(
                selected = selected == destination,
                onClick = { if (selected != destination) select(destination) },
                modifier = Modifier.fillMaxWidth().heightIn(min = 88.dp).semantics { contentDescription = label },
                icon = { Icon(destination.icon(selected == destination), null, Modifier.size(24.dp)) },
                label = { DestinationLabel(destination) },
                alwaysShowLabel = true,
            )
            Spacer(Modifier.height(8.dp))
        }
    }
}
