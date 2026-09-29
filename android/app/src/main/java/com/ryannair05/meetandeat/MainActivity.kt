package com.ryannair05.meetandeat

import android.os.Bundle
import androidx.core.content.edit
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Alignment
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext

@Composable
fun MyApp() {
    val context = LocalContext.current
    val preferences = remember { context.getSharedPreferences("halls-onboarding", android.content.Context.MODE_PRIVATE) }
    var onboarded by rememberSaveable { mutableStateOf(preferences.getBoolean("completed-v1", false)) }
    DiningTheme {
        if (onboarded) AppScaffold()
        else OnboardingScreen {
            preferences.edit { putBoolean("completed-v1", true) }
            onboarded = true
        }
    }
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            MyApp()
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AppScaffold() {
    var destination by rememberSaveable { mutableStateOf(AppDestination.MEALS) }
    val tabState = rememberSaveableStateHolder()
    var warmCata by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        // Let the initial screen draw before initializing the native map behind it.
        withFrameNanos { }
        withFrameNanos { }
        warmCata = true
    }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(Unit) {
        com.ryannair05.meetandeat.journal.MealFeedback.messages.collect { snackbar.showSnackbar(it) }
    }
    // Registered before child navigators so a detail route/search/sheet handles Back first.
    androidx.activity.compose.BackHandler(enabled = destination != AppDestination.MEALS) {
        destination = AppDestination.MEALS
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val rail = maxWidth >= 600.dp || (maxWidth >= 480.dp && maxHeight < 480.dp)
        val keyboardOpen = WindowInsets.isImeVisible
        Row(Modifier.fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))
            .imePadding()) {
            if (rail) AppNavigationRail(destination) { destination = it }
            Scaffold(
                modifier = Modifier.weight(1f),
                containerColor = MaterialTheme.colorScheme.surface,
                contentWindowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom),
                snackbarHost = { SnackbarHost(snackbar) },
                bottomBar = {
                    if (!rail && !keyboardOpen) {
                        Box(Modifier.fillMaxWidth()
                            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom))
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                            contentAlignment = Alignment.Center) {
                            AppNavigationBar(destination) { destination = it }
                        }
                    }
                },
            ) { innerPadding ->
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
                    // Reading screens have a bounded measure; the map uses the entire workspace.
                    val contentModifier = Modifier.widthIn(max = 1000.dp).fillMaxSize()
                        .padding(innerPadding).consumeWindowInsets(innerPadding)
                    val cataActive = destination == AppDestination.CATA
                    if (warmCata || cataActive) {
                        // Keep the MapView placed and on the activity lifecycle. Stopping or
                        // unplacing it discards the rendered surface even when tiles are cached.
                        // CataBusScreen separately gates live work on the selected tab.
                        tabState.SaveableStateProvider(AppDestination.CATA.name) {
                            val visibility = if (cataActive) Modifier else Modifier.clearAndSetSemantics { }
                            Box(visibility
                                .graphicsLayer { alpha = if (cataActive) 1f else 0f }
                                .focusProperties { canFocus = cataActive }
                                .pointerInput(cataActive) {
                                    if (!cataActive) awaitPointerEventScope {
                                        while (true) {
                                            awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
                                        }
                                    }
                                }) {
                                CataBusScreen(bottomOverlay = innerPadding.calculateBottomPadding(), active = cataActive)
                            }
                        }
                    }
                    if (!cataActive) tabState.SaveableStateProvider(destination.name) {
                        when (destination) {
                            AppDestination.MEALS -> DiningHallListScreen(contentModifier)
                            AppDestination.MY_MEALS -> com.ryannair05.meetandeat.journal.MyMealsScreen(contentModifier)
                            AppDestination.CATA -> Unit
                            AppDestination.RECREATION -> ScheduleScreen(contentModifier)
                        }
                    }
                }
            }
        }
    }
}
