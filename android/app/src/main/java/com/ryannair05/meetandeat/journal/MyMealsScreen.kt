package com.ryannair05.meetandeat.journal

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ryannair05.meetandeat.dining.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MyMealsScreen(modifier: Modifier = Modifier) {
    com.ryannair05.meetandeat.TrackScreen("my_meals")
    val context = LocalContext.current
    val journal = remember { MealJournal.get(context) }
    val meals by journal.meals.collectAsState()
    val draftStore = remember { PlateDraftStore.get(context) }
    val drafts by draftStore.drafts.collectAsState()
    var resuming by rememberSaveable { mutableStateOf<String?>(null) }
    val draftError by draftStore.error.collectAsState()
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var openingEditor by remember { mutableStateOf(false) }
    var filter by rememberSaveable { mutableIntStateOf(0) }
    var deleting by remember { mutableStateOf<JournalMeal?>(null) }
    val today = LocalDate.now(PennStateZone)
    suspend fun action(block: suspend () -> Unit) {
        try { block(); error = null } catch (e: CancellationException) { throw e }
        catch (e: Exception) { error = e.message ?: "Couldn't save your meal. Try again." }
    }
    fun openMealEditor(meal: JournalMeal) {
        if (openingEditor) return
        openingEditor = true
        scope.launch { try { action {
            draftStore.load()
            val key = "edit:${meal.id}"
            if (draftStore.drafts.value.none { it.key == key }) draftStore.update(PlateDraft(key, meal, meal.date, meal.items.map { it.item }))
            resuming = key
        } } finally { openingEditor = false } }
    }
    LaunchedEffect(journal) { action { journal.load(); loaded = true } }
    LaunchedEffect(draftStore) {
        try { draftStore.load() }
        catch (e: CancellationException) { throw e }
        catch (_: Exception) { /* Saved journal entries remain available if drafts cannot load. */ }
    }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/csv")) { uri ->
        if (uri != null) scope.launch { action {
            withContext(Dispatchers.IO) {
                val csv = journal.csv()
                requireNotNull(context.contentResolver.openOutputStream(uri)).bufferedWriter().use { it.write(csv) }
            }
        } }
    }
    Scaffold(modifier = modifier, topBar = { TopAppBar(title = { Text("My Meals") }, actions = {
        IconButton(enabled = loaded && meals.isNotEmpty(), onClick = { export.launch("Halls-meals-$today.csv") }) {
            Icon(Icons.Default.FileDownload, "Export journal")
        }
    }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("History", "Planned", "Nutrition").forEachIndexed { index, label ->
                    FilterChip(selected = filter == index, onClick = { filter = index }, label = { Text(label) })
                }
            } }
            error?.let { message -> item { Text(message, color = MaterialTheme.colorScheme.error) } }
            draftError?.let { message -> item { Text(message, color = MaterialTheme.colorScheme.error) } }
            if (loaded && drafts.isNotEmpty()) {
                item { Text("Unfinished plates", style = MaterialTheme.typography.titleMedium) }
                items(drafts, key = { "draft-${it.key}" }) { draft ->
                    OutlinedCard(onClick = { resuming = draft.key }, modifier = Modifier.fillMaxWidth()) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("${PSUDiningHall.fromId(draft.meal.hallId)?.displayName.orEmpty()} · ${draft.meal.meal}")
                                Text("${draft.meal.items.size} foods · Resume plate", style = MaterialTheme.typography.bodySmall)
                            }
                            Icon(Icons.Default.ChevronRight, null)
                        }
                    }
                }
            }
            if (!loaded && error == null) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            if (loaded && filter == 2) {
                item { Text("Last 7 days · eaten meals", style = MaterialTheme.typography.titleMedium) }
                val days = (0L..6L).map { today.minusDays(it) }
                items(days, key = { it.toString() }) { day ->
                    val dailyItems = meals.filter { it.eaten && it.date == day.toString() }.flatMap { it.items }
                    Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(day.toString(), fontWeight = FontWeight.SemiBold)
                        Text(if (dailyItems.isEmpty()) "No meals logged" else nutritionSummary(dailyItems))
                    } }
                }
                item { Text("Totals use Penn State's published serving sizes. Missing amounts stay unknown; partial totals include only foods with published values.", style = MaterialTheme.typography.bodySmall) }
            } else if (loaded) {
                val visible = meals.filter { it.eaten == (filter == 0) }
                if (visible.isEmpty()) item {
                    Text(if (filter == 0) "No meals logged yet" else "No meals planned yet", style = MaterialTheme.typography.titleLarge)
                    Text("Open a dining menu and tap the plate button to choose foods, adjust portions, and save a meal.")
                }
                items(visible, key = { it.id }) { meal ->
                    Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("${PSUDiningHall.fromId(meal.hallId)?.displayName ?: meal.hallId} · ${meal.meal}", style = MaterialTheme.typography.titleMedium)
                        Text(meal.date, style = MaterialTheme.typography.labelLarge)
                        Text(meal.items.joinToString("\n") { "${it.item.name} × ${it.servings}" })
                        Text(nutritionSummary(meal.items), style = MaterialTheme.typography.bodySmall)
                        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(enabled = !openingEditor, onClick = { openMealEditor(meal) }) { Text("Edit") }
                            TextButton(enabled = !openingEditor, onClick = { openMealEditor(meal.copy(id = UUID.randomUUID().toString(), date = today.toString(), eaten = false)) }) { Text("Repeat") }
                            if (!meal.eaten) TextButton(onClick = { scope.launch { action { journal.save(meal.copy(eaten = true, date = today.toString())) } } }) { Text("Eaten today") }
                            IconButton(onClick = { deleting = meal }) { Icon(Icons.Default.DeleteOutline, "Delete meal") }
                        }
                    } }
                }
            }
        }
    }
    drafts.firstOrNull { it.key == resuming }?.let { draft ->
        PlateEditor(PSUDiningHall.fromId(draft.meal.hallId) ?: PSUDiningHall.SOUTH,
            LocalDate.parse(draft.sourceDate), draft.meal.meal, draft.candidates, draft.meal,
            draftKey = draft.key, onDismiss = { resuming = null })
    }
    deleting?.let { meal -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text("Delete this meal?") },
        text = { Text("This removes the meal and its nutrition from your journal.") },
        confirmButton = { TextButton(onClick = { scope.launch { action { journal.delete(meal.id); deleting = null } } }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } }) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlateEditor(
    hall: PSUDiningHall,
    date: LocalDate,
    mealName: String,
    candidates: List<DiningMenuItem>,
    existing: JournalMeal? = null,
    initialDetail: MenuItemDetail? = null,
    draftKey: String? = null,
    onDismiss: () -> Unit,
) {
    com.ryannair05.meetandeat.TrackScreen("plate_editor")
    val context = LocalContext.current
    val journal = remember { MealJournal.get(context) }
    val repository = remember { DiningGraph.repository(context) }
    val draftStore = remember { PlateDraftStore.get(context) }
    val key = remember { draftKey ?: existing?.let { "edit:${it.id}" } ?: "plate:${hall.id}:$date:$mealName" }
    var recordId by remember { mutableStateOf(existing?.id ?: UUID.randomUUID().toString()) }
    var restored by remember { mutableStateOf(false) }
    var confirmsDiscard by remember { mutableStateOf(false) }
    val draftError by draftStore.error.collectAsState()
    val scope = rememberCoroutineScope()
    var selected by remember { mutableStateOf(existing?.items ?: candidates.takeIf { it.size == 1 }?.map { JournalItem(it, detail = initialDetail) }.orEmpty()) }
    var eaten by remember { mutableStateOf(existing?.eaten ?: !date.isAfter(LocalDate.now(PennStateZone))) }
    var selectedDate by remember { mutableStateOf(date) }
    var datePicker by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var finished by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var foods by remember { mutableStateOf(candidates.distinctBy { it.id }) }
    var loadingNutrition by remember { mutableStateOf(false) }
    var attempted by remember { mutableStateOf(emptySet<String>()) }
    val nutritionRequests = remember { Semaphore(3) }
    LaunchedEffect(key) {
        try {
            draftStore.load()
            draftStore.drafts.value.firstOrNull { it.key == key }?.let { draft ->
                recordId = draft.meal.id
                selected = draft.meal.items
                selectedDate = LocalDate.parse(draft.meal.date)
                eaten = draft.meal.eaten
                foods = (draft.candidates + candidates).distinctBy { it.id }
            }
            restored = true
        } catch (e: CancellationException) { throw e }
        catch (_: Exception) { error = "Couldn't restore your draft. Close and try again." }
    }
    fun preserveDraft() {
        if (restored && !finished) {
            if (selected.isEmpty() && existing == null && draftStore.drafts.value.none { it.key == key }) return
            draftStore.update(PlateDraft(key,
                JournalMeal(recordId, hall.id, selectedDate.toString(), mealName, eaten, selected), date.toString(), foods))
        }
    }
    LaunchedEffect(selected, selectedDate, eaten, restored) {
        if (!saving) preserveDraft()
    }
    DisposableEffect(key) {
        onDispose { preserveDraft() }
    }
    LaunchedEffect(existing?.id) {
        if (existing != null) {
            try {
                val menu = repository.menu(hall, date)
                val matching = menu.meals.firstOrNull { it.name.equals(mealName, true) }
                foods = (candidates + matching?.sections.orEmpty().flatMap { it.items }).distinctBy { it.id }
            } catch (e: CancellationException) { throw e } catch (_: Exception) { /* Saved foods remain editable offline. */ }
        }
    }
    LaunchedEffect(selected.map { it.item.id }, restored) {
        if (!restored) return@LaunchedEffect
        val pending = selected.filter { it.detail == null && it.item.id !in attempted }
        loadingNutrition = pending.isNotEmpty()
        try {
            coroutineScope {
                pending.map { row -> async {
                    val detail = try { nutritionRequests.withPermit { repository.itemDetail(row.item, hall, date) } }
                    catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                    attempted = attempted + row.item.id
                    selected = selected.map { if (it.item.id == row.item.id) it.copy(detail = detail) else it }
                } }.awaitAll()
            }
        } finally { loadingNutrition = false }
    }
    fun update(item: DiningMenuItem, delta: Double) {
        val current = selected.firstOrNull { it.item.id == item.id }
        selected = if (current == null) selected + JournalItem(item)
        else if (current.servings + delta < 0.25) selected.filterNot { it.item.id == item.id }
        else selected.map { if (it.item.id == item.id) it.copy(servings = (it.servings + delta).coerceAtMost(20.0)) else it }
    }
    ModalBottomSheet(onDismissRequest = { if (!saving) { preserveDraft(); onDismiss() } }, sheetState = rememberBottomSheetState(initialValue = SheetValue.Hidden, enabledValues = setOf(SheetValue.Hidden, SheetValue.Expanded))) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.9f).padding(horizontal = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(if (existing == null) "Build a plate" else "Edit meal", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
                IconButton(enabled = restored && !saving, onClick = { confirmsDiscard = true }) { Icon(Icons.Default.DeleteOutline, "Discard unfinished plate") }
            }
            if (!restored && error == null) LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("${hall.displayName} · $mealName", style = MaterialTheme.typography.titleMedium)
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(enabled = restored && !saving, onClick = { datePicker = true }) { Text(selectedDate.toString()) }
                Spacer(Modifier.weight(1f))
                FilterChip(enabled = restored && !saving, selected = !eaten, onClick = { eaten = false }, label = { Text("Planned") })
                Spacer(Modifier.width(8.dp))
                FilterChip(enabled = restored && !saving && !selectedDate.isAfter(LocalDate.now(PennStateZone)), selected = eaten, onClick = { eaten = true }, label = { Text("Eaten") })
            }
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), placeholder = { Text("Find food for this plate") }, singleLine = true)
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(vertical = 8.dp)) {
                items(foods.filter { it.name.contains(query, true) }, key = { it.id }) { item ->
                    val portion = selected.firstOrNull { it.item.id == item.id }
                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(item.name)
                            portion?.detail?.nutrition?.firstOrNull { normalizeDiningText(it.name) == "serving size" }?.let { Text("1 serving: ${it.value}", style = MaterialTheme.typography.bodySmall) }
                        }
                        if (portion != null) {
                            IconButton(enabled = restored && !saving, onClick = { update(item, -0.25) }) { Icon(Icons.Default.Remove, "Reduce servings") }
                            Text(portion.servings.toString())
                        }
                        IconButton(enabled = restored && !saving && (portion?.servings ?: 0.0) < 20, onClick = { update(item, 0.25) }) { Icon(Icons.Default.Add, "Add serving") }
                    }
                }
            }
            if (loadingNutrition) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (selected.isNotEmpty()) Text("${selected.size} foods · ${nutritionSummary(selected)}", style = MaterialTheme.typography.bodySmall)
            if (!loadingNutrition && selected.any { it.detail == null }) Text("Some nutrition is unavailable. You can still save this meal; totals will be partial.", style = MaterialTheme.typography.bodySmall)
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            draftError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(enabled = restored && !saving && selected.isNotEmpty(), modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp), onClick = {
                if (saving) return@Button
                saving = true
                error = null
                scope.launch {
                    try {
                        // Logging never waits for the network. Keep unknown nutrition explicit.
                        journal.save(JournalMeal(id = recordId, hallId = hall.id, date = selectedDate.toString(), meal = mealName, eaten = eaten, items = selected))
                        finished = true
                        draftStore.remove(key)
                        MealFeedback.messages.tryEmit(if (eaten) "Meal logged" else "Meal planned")
                        onDismiss()
                    } catch (e: CancellationException) { throw e }
                    catch (e: Exception) { error = e.message ?: "Couldn't save this meal. Try again." }
                    finally { saving = false }
                }
            }) { Text(if (saving) "Saving…" else if (eaten) "Log meal" else "Save planned meal") }
        }
    }
    if (confirmsDiscard) AlertDialog(onDismissRequest = { confirmsDiscard = false },
        title = { Text("Discard unfinished changes?") }, text = { Text("Any previously saved meal stays in your journal.") },
        confirmButton = { TextButton(onClick = { finished = true; draftStore.remove(key); confirmsDiscard = false; onDismiss() }) { Text("Discard") } },
        dismissButton = { TextButton(onClick = { confirmsDiscard = false }) { Text("Keep editing") } })
    if (datePicker) {
        val picker = rememberDatePickerState(initialSelectedDateMillis = selectedDate.atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli())
        DatePickerDialog(onDismissRequest = { datePicker = false }, confirmButton = {
            TextButton(onClick = { picker.selectedDateMillis?.let { selectedDate = java.time.Instant.ofEpochMilli(it).atZone(java.time.ZoneOffset.UTC).toLocalDate(); if (selectedDate.isAfter(LocalDate.now(PennStateZone))) eaten = false }; datePicker = false }) { Text("Done") }
        }, dismissButton = { TextButton(onClick = { datePicker = false }) { Text("Cancel") } }) { DatePicker(picker) }
    }
}
