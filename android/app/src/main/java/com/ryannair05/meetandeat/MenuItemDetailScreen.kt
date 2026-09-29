package com.ryannair05.meetandeat

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.spring
import android.app.Application
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ryannair05.meetandeat.dining.DiningMenuItem
import com.ryannair05.meetandeat.dining.LoadState
import com.ryannair05.meetandeat.dining.MenuItemDetailFailureKind
import com.ryannair05.meetandeat.dining.MenuItemDetailUiState
import com.ryannair05.meetandeat.dining.MenuItemDetailViewModel
import com.ryannair05.meetandeat.dining.MenuTrait
import com.ryannair05.meetandeat.dining.MenuTraitClassifier
import com.ryannair05.meetandeat.dining.NutritionFact
import com.ryannair05.meetandeat.dining.PSUDiningHall
import com.ryannair05.meetandeat.dining.normalizeDiningText
import com.ryannair05.meetandeat.dining.simpleViewModelFactory
import com.ryannair05.meetandeat.share.ItemShareSheet
import java.time.LocalDate

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun MenuItemDetailScreen(
    route: DiningItemRoute,
    onBack: () -> Unit,
    onOpenHall: (PSUDiningHall, LocalDate) -> Unit,
) {
    TrackScreen("menu_item", "menu_item_${route.itemId}")
    val context = LocalContext.current
    val application = context.applicationContext as Application
    val item = remember(route) { DiningMenuItem(route.itemId, route.itemName, route.detailUrl, 0, route.labels) }
    val date = remember(route.date) { LocalDate.parse(route.date) }
    val vm: MenuItemDetailViewModel = viewModel(
        key = "detail-${route.itemId}-${route.date}-${route.includeAvailability}",
        factory = remember(route) {
            simpleViewModelFactory {
                MenuItemDetailViewModel(application, item, route.hall, date, route.includeAvailability)
            }
        },
    )
    val state by vm.state.collectAsState()
    val shareDetail = (state.detail as? LoadState.Ready)?.value
    var shareVisible by rememberSaveable { mutableStateOf(false) }
    var plateVisible by rememberSaveable { mutableStateOf(false) }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.surface,
        topBar = {
            TopAppBar(
                title = {},
                navigationIcon = { IconButton(onClick = onBack) { Icon(DiningSymbols.ArrowBack, "Back") } },
                actions = {
                    IconButton(
                        enabled = shareDetail != null,
                        onClick = { shareVisible = true },
                    ) { Icon(DiningSymbols.Share, "Share item details") }
                },
            )
        },
    ) { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding)) {
            if (maxWidth >= 720.dp && route.includeAvailability) {
                Row(Modifier.fillMaxSize().padding(24.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    Surface(
                        modifier = Modifier.width(300.dp).fillMaxHeight(),
                        shape = MaterialTheme.shapes.extraLarge,
                        color = MaterialTheme.colorScheme.surfaceContainerLow,
                    ) { AvailabilityPane(state, onOpenHall) }
                    DetailContent(state, vm::refresh, Modifier.weight(1f), onLog = { plateVisible = true })
                }
            } else DetailContent(
                state,
                vm::refresh,
                Modifier.fillMaxSize(),
                onOpenHall.takeIf { route.includeAvailability },
                onLog = { plateVisible = true },
            )
        }
    }
    if (plateVisible) {
        com.ryannair05.meetandeat.journal.PlateEditor(route.hall, date,
            route.meal, listOf(item), initialDetail = shareDetail, onDismiss = { plateVisible = false })
    }
    if (shareVisible && shareDetail != null) {
        ItemShareSheet(
            hall = route.hall,
            date = date,
            mealName = route.meal,
            item = state.item,
            detail = shareDetail,
            onDismiss = { shareVisible = false },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DetailContent(
    state: MenuItemDetailUiState,
    onRetry: () -> Unit,
    modifier: Modifier,
    onOpenHall: ((PSUDiningHall, LocalDate) -> Unit)? = null,
    onLog: () -> Unit,
) {
    val context = LocalContext.current
    if (state.detail !is LoadState.Ready) {
        Column(modifier) {
            Text(state.item.name, Modifier.padding(horizontal = DiningSpacing.page, vertical = 16.dp), style = MaterialTheme.typography.headlineMedium)
            FoodLogButton(onLog, Modifier.padding(horizontal = DiningSpacing.page))
            DetailLoadState(state, onRetry, Modifier.weight(1f).fillMaxWidth())
        }
        return
    }
    val detail = state.detail.value
    LazyColumn(
        modifier = modifier,
        contentPadding = PaddingValues(horizontal = DiningSpacing.page, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        item {
            Text(state.item.name, style = MaterialTheme.typography.headlineMedium)
        }
        if (detail.nutrition.isNotEmpty()) item { MacroSummary(detail.nutrition) }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val traits = (MenuTraitClassifier.classify(state.item.sourceLabels, state.item.name)
                    .withoutGenericAllergenWarning() + detail.allergenStatement?.let {
                        MenuTraitClassifier.classifyAllergens(it).withoutGenericAllergenWarning().filter(MenuTrait::isAllergen)
                    }.orEmpty()).distinct()
                if (traits.isNotEmpty()) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    traits.forEach { AllergenChip(it) }
                }
                FoodLogButton(onLog)
            }
        }
        item { IngredientsCard(detail.ingredients) }
        if (detail.nutrition.isNotEmpty()) item { NutritionFactsCard(detail.nutrition) }
        if (onOpenHall != null && state.availability.isNotEmpty()) item {
            SectionHeader("Available at")
            AvailabilityPane(state, onOpenHall, showTitle = false)
        }
        item {
            OutlinedButton(onClick = {
                context.startActivity(Intent(Intent.ACTION_VIEW, detail.sourceUrl.toUri()))
            }, modifier = Modifier.fillMaxWidth()) {
                Icon(DiningSymbols.OpenInBrowser, null)
                Spacer(Modifier.width(8.dp))
                Text("View official source")
            }
        }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun FoodLogButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    TextButton(onClick = onClick, modifier = modifier) {
        Icon(DiningSymbols.Restaurant, null, Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text("Log or plan this food")
    }
}

@Composable
private fun DetailLoadState(state: MenuItemDetailUiState, onRetry: () -> Unit, modifier: Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        when (val load = state.detail) {
            LoadState.Idle, is LoadState.Loading -> DiningLoadingState("Loading nutrition and ingredients")
            is LoadState.Empty -> DiningEmptyState("Details not published", load.message)
            is LoadState.Error -> Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        if (state.failureKind == MenuItemDetailFailureKind.MARKUP) DiningSymbols.Warning else DiningSymbols.WifiOff,
                        null,
                        Modifier.size(52.dp),
                        tint = diningUpcomingColor(),
                    )
                    Spacer(Modifier.height(16.dp))
                    Text(
                        if (state.failureKind == MenuItemDetailFailureKind.MARKUP) "Penn State changed this page"
                        else "Couldn't reach Penn State",
                        style = MaterialTheme.typography.headlineSmall,
                    )
                    Text(load.message, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(16.dp))
                    Button(onClick = onRetry) { Text("Try again") }
                }
            }
            is LoadState.Ready -> Unit
        }
    }
}

@Composable
private fun AvailabilityPane(
    state: MenuItemDetailUiState,
    onOpenHall: (PSUDiningHall, LocalDate) -> Unit,
    showTitle: Boolean = true,
) {
    Column(
        modifier = Modifier.padding(if (showTitle) 16.dp else 0.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (showTitle) {
            Text("Available at", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        }
        if (state.availability.isEmpty()) {
            Text("Checking dining halls…", color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else state.availability.forEach { appearance ->
            Card(
                onClick = { onOpenHall(appearance.hall, appearance.date) },
                modifier = Modifier.fillMaxWidth(),
                shape = MaterialTheme.shapes.large,
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                    contentColor = MaterialTheme.colorScheme.onSurface,
                ),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            appearance.hall.displayName,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            appearance.mealNames.joinToString(" · "),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Icon(
                        DiningSymbols.ChevronRight,
                        contentDescription = "Open ${appearance.hall.displayName} menu",
                    )
                }
            }
        }
    }
}

@Composable
private fun IngredientsCard(ingredients: String?) {
    var expanded by rememberSaveable(ingredients) { mutableStateOf(false) }
    var overflows by remember(ingredients) { mutableStateOf(false) }
    Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.fillMaxWidth().animateContentSize(spring(dampingRatio = 1f, stiffness = 550f)).padding(16.dp)) {
            Text("Ingredients", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(8.dp))
            Text(
                ingredients ?: "Penn State did not provide an ingredient list.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = if (expanded) Int.MAX_VALUE else 5,
                overflow = TextOverflow.Ellipsis,
                onTextLayout = { if (!expanded) overflows = it.hasVisualOverflow },
            )
            if (expanded || overflows) TextButton(onClick = { expanded = !expanded }) {
                Text(if (expanded) "Show less" else "Show all")
            }
        }
    }
}

@Composable
private fun NutritionFactsCard(facts: List<NutritionFact>) {
    val serving = facts.firstOrNull { normalizeDiningText(it.name) == "serving size" }
    val calories = facts.firstOrNull { normalizeDiningText(it.name) == "calories" }
    val others = facts.filterNot { it === serving || it === calories || normalizeDiningText(it.name) == "calories from fat" }
    Surface(
        shape = MaterialTheme.shapes.small,
        color = MaterialTheme.colorScheme.surfaceContainerLowest,
    ) {
        Column {
            SectionHeader("Detailed Nutrition")
            serving?.let { FactRow(it, true) }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                Text("Calories", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Text(calories?.value ?: "—", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Medium)
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Text("% Daily Value*", style = MaterialTheme.typography.labelMedium, modifier = Modifier.align(Alignment.End).padding(vertical = 4.dp))
            others.forEach { fact -> FactRow(fact, normalizeDiningText(fact.name) in setOf("total fat", "total carbohydrate", "protein")) }
            Text(
                "* Percent Daily Values are based on a 2,000 calorie diet.",
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}

@Composable
private fun FactRow(fact: NutritionFact, bold: Boolean) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Text(fact.name, Modifier.weight(1f), fontWeight = if (bold) FontWeight.Bold else FontWeight.Normal)
        Text(fact.value, fontWeight = if (bold) FontWeight.Bold else FontWeight.Normal)
    }
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
}
