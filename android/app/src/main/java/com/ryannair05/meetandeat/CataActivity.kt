package com.ryannair05.meetandeat

import android.Manifest
import android.annotation.SuppressLint
import android.app.Application
import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.draw.shadow
import android.animation.ValueAnimator
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.layout.onSizeChanged
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.compose.LifecycleStartEffect
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.*
import com.ryannair05.meetandeat.cata.*
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.isGranted
import com.google.accompanist.permissions.rememberPermissionState
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.combine
import android.graphics.Color as AndroidColor

@SuppressLint("PotentialBehaviorOverride")
@OptIn(ExperimentalPermissionsApi::class, ExperimentalMaterial3Api::class, MapsComposeExperimentalApi::class)
@Composable
fun CataBusScreen(modifier: Modifier = Modifier, bottomOverlay: Dp = 0.dp, active: Boolean = true) {
    if (active) TrackScreen("cata")
    if (!BuildConfig.MAPS_CONFIGURED) {
        Box(modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Text(androidx.compose.ui.res.stringResource(R.string.cata_maps_unavailable))
        }
        return
    }
    val context = LocalContext.current
    val application = context.applicationContext as Application
    val vm: MapVM = viewModel(factory = remember { VMFactory(application) })
    val traces by vm.traces.collectAsState()
    val busCount by remember(vm) { vm.buses.map { it.size }.distinctUntilChanged() }.collectAsState(initial = 0)
    val selectedStop by vm.selectedStop.collectAsState()
    val selectedBus by vm.selectedBus.collectAsState()
    val routes by vm.routes.collectAsState()
    val selectedRoutes by vm.selected.collectAsState()
    val routeError by vm.routeError.collectAsState()
    val mapMessage by vm.mapMessage.collectAsState()
    val vehicleStatus by vm.vehicleStatus.collectAsState()
    val vehiclesStale by vm.vehiclesStale.collectAsState()
    val mapBounds by vm.mapBounds.collectAsState()
    val userLocation by vm.userLocation.collectAsState()
    val permission = rememberPermissionState(Manifest.permission.ACCESS_FINE_LOCATION) {
        vm.updateLocationPermission()
    }
    val cameraState = rememberCameraPositionState {
        position = CameraPosition.fromLatLngZoom(LatLng(40.7982, -77.8599), 14f)
    }
    val scope = rememberCoroutineScope()
    var showRoutes by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    val window = (context as? android.app.Activity)?.window
    DisposableEffect(window, active) {
        val previousContrast = window?.isNavigationBarContrastEnforced
        if (active) window?.isNavigationBarContrastEnforced = false
        onDispose { if (active) previousContrast?.let { window.isNavigationBarContrastEnforced = it } }
    }
    val statusInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    var requestedLocation by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(active) {
        if (active && !requestedLocation) {
            requestedLocation = true
            if (!permission.status.isGranted) permission.launchPermissionRequest()
        }
    }
    LifecycleStartEffect(vm, active) {
        vm.setScreenActive(active)
        onStopOrDispose { vm.setScreenActive(false) }
    }

    BoxWithConstraints(modifier.fillMaxSize()) {
        val wide = maxWidth >= 720.dp
        androidx.activity.compose.BackHandler(enabled = active && wide && (showRoutes || selectedStop != null || selectedBus != null)) {
            showRoutes = false
            vm.clearSelection()
        }
        Row(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f).fillMaxHeight()) {
                CataMap(
                    context, vm, active, active && permission.status.isGranted, selectedRoutes, traces, routes,
                    cameraState, mapBounds, selectedBus?.id,
                    PaddingValues(top = statusInset + 88.dp, bottom = bottomOverlay + 8.dp),
                )
                // A narrow system-bar scrim protects icons while leaving the map edge-to-edge.
                Box(Modifier.fillMaxWidth().height(statusInset + 12.dp).background(Brush.verticalGradient(
                    listOf(MaterialTheme.colorScheme.surface, Color.Transparent))))
                Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                    .height(WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 8.dp)
                    .background(Brush.verticalGradient(listOf(Color.Transparent, MaterialTheme.colorScheme.surface))))
                Column(Modifier.align(Alignment.TopCenter)
                    .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal))
                    .padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.weight(1f)) {
                            Surface(shape = MaterialTheme.shapes.extraLarge,
                                color = MaterialTheme.colorScheme.surfaceContainer, tonalElevation = 3.dp, shadowElevation = 3.dp) {
                                Column(Modifier.padding(horizontal = 20.dp, vertical = 12.dp)) {
                                    Text("CATA", style = MaterialTheme.typography.titleMedium)
                                    Text(if (vehiclesStale || busCount == 0) vehicleStatus else androidx.compose.ui.res.pluralStringResource(R.plurals.cata_bus_count, busCount, busCount),
                                        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 2, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                                }
                            }
                        }
                        MapControl(ImageVector.vectorResource(R.drawable.symbol_my_location), if (userLocation != null) "Center on my location" else "Center selected routes") {
                            if (active && !permission.status.isGranted) permission.launchPermissionRequest()
                            scope.launch {
                                val update = userLocation?.let { CameraUpdateFactory.newLatLngZoom(LatLng(it.latitude, it.longitude), 16f) }
                                    ?: mapBounds?.let { CameraUpdateFactory.newLatLngBounds(it, 64) }
                                if (update != null) {
                                    if (ValueAnimator.areAnimatorsEnabled()) cameraState.animate(update, 500) else cameraState.move(update)
                                }
                            }
                        }
                        MapControl(DiningSymbols.FilterList, "Choose routes") { vm.clearSelection(); showRoutes = !showRoutes }
                    }
                    AnimatedVisibility(routeError != null || mapMessage != null) {
                        Surface(
                            shape = MaterialTheme.shapes.large,
                            color = MaterialTheme.colorScheme.tertiaryContainer,
                            contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
                        ) {
                            Text(routeError ?: mapMessage.orEmpty(), Modifier.padding(horizontal = 16.dp, vertical = 10.dp), style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }
            if (wide && (showRoutes || selectedStop != null || selectedBus != null)) {
                Surface(
                    modifier = Modifier.widthIn(min = 320.dp, max = 420.dp).fillMaxHeight()
                        .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.End))
                        .padding(bottom = bottomOverlay),
                    color = MaterialTheme.colorScheme.surfaceContainerLow,
                ) {
                    Column {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                            IconButton(onClick = { showRoutes = false; vm.clearSelection() }) { Icon(DiningSymbols.Close, "Close pane") }
                        }
                        when {
                            showRoutes -> {
                                var query by remember { mutableStateOf("") }
                                val selected by vm.selected.collectAsState()
                                val loading by vm.routeLoading.collectAsState()
                                RoutePickerContent(
                                    routes.filter { query.isBlank() || it.longName.contains(query, true) || it.abbr.contains(query, true) },
                                    selected, loading, routeError, query, { query = it }, vm::toggle, vm::refreshRoutes,
                                )
                            }
                            selectedStop != null -> StopSheet(selectedStop!!, vm)
                            selectedBus != null -> BusSheet(selectedBus!!, routes.firstOrNull { it.routeId == selectedBus!!.routeId })
                        }
                    }
                }
            }
        }
        if (active && !wide) {
            val stopSheetState = rememberBottomSheetState(
                initialValue = SheetValue.Hidden,
                enabledValues = setOf(SheetValue.Hidden, SheetValue.Expanded),
            )
            if (showRoutes) RoutePickerSheet(vm) { showRoutes = false }
            selectedStop?.let { stop ->
                ModalBottomSheet(
                    onDismissRequest = vm::clearSelection,
                    sheetState = stopSheetState,
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                    scrimColor = Color.Transparent,
                ) {
                    Box(Modifier.fillMaxWidth().fillMaxHeight(.75f)) {
                        StopSheet(stop, vm, Modifier.fillMaxSize())
                    }
                }
            }
            selectedBus?.let { bus ->
                ModalBottomSheet(
                    onDismissRequest = vm::clearSelection,
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                    scrimColor = Color.Transparent,
                ) { BusSheet(bus, routes.firstOrNull { it.routeId == bus.routeId }) }
            }
        }

    }
}

@Composable
private fun MapControl(icon: ImageVector, description: String, onClick: () -> Unit) {
    FilledTonalIconButton(onClick = onClick, shapes = IconButtonDefaults.shapes(),
        modifier = Modifier.size(56.dp).shadow(3.dp, MaterialTheme.shapes.extraLarge),
        colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            contentColor = MaterialTheme.colorScheme.onSurface)) { Icon(icon, description) }
}

@OptIn(MapsComposeExperimentalApi::class)
@Composable
private fun CataMap(
    context: Context,
    vm: MapVM,
    active: Boolean,
    hasLocationPermission: Boolean,
    selectedRoutes: Set<String>,
    traces: Map<String, RouteTrace>,
    routes: List<RouteModel>,
    cameraState: CameraPositionState,
    mapBounds: com.google.android.gms.maps.model.LatLngBounds?,
    selectedBusId: Int?,
    mapPadding: PaddingValues,
) {
    var mapSize by remember { mutableStateOf(IntSize.Zero) }
    val density = LocalDensity.current.density
    val markerController = remember(context, vm) {
        CataMarkerController(context.applicationContext, vm::selectStop, vm::selectBus)
    }
    var fittedSelection by remember(selectedRoutes) { mutableStateOf(false) }
    LaunchedEffect(cameraState.isMoving, cameraState.cameraMoveStartedReason) {
        if (cameraState.isMoving && cameraState.cameraMoveStartedReason == CameraMoveStartedReason.GESTURE) {
            fittedSelection = true
        }
    }
    // Position updates go straight to native markers; they do not recompose the map and route lines.
    LaunchedEffect(markerController, vm) {
        vm.stops.collect { markerController.updateStops(it.values.flatten().distinctBy(StopInfo::id)) }
    }
    LaunchedEffect(markerController, vm) {
        combine(vm.buses, vm.vehiclesStale) { buses, stale -> buses to stale }.collect { (buses, stale) ->
            markerController.updateBuses(buses.values, stale)
        }
    }
    LaunchedEffect(markerController, selectedBusId) { markerController.selectBus(selectedBusId) }
    DisposableEffect(markerController) { onDispose(markerController::detach) }
    GoogleMap(
        modifier = Modifier.fillMaxSize().onSizeChanged { mapSize = it },
        focusable = active,
        uiSettings = MapUiSettings(zoomControlsEnabled = false, myLocationButtonEnabled = false, compassEnabled = false, mapToolbarEnabled = false),
        cameraPositionState = cameraState,
        contentPadding = mapPadding,
        mapColorScheme = if (isSystemInDarkTheme()) ComposeMapColorScheme.DARK else ComposeMapColorScheme.LIGHT,
        onMapClick = { vm.clearSelection() },
        onMapLoaded = { vm.reportTiming("Map tiles ready") },
        properties = MapProperties(isMyLocationEnabled = hasLocationPermission, mapType = MapType.NORMAL),
    ) {
        MapEffect(markerController) { map ->
            markerController.attach(map)
            markerController.claimMarkerClicks()
            vm.reportTiming("Map attached")
        }
        LaunchedEffect(selectedRoutes, mapBounds, mapSize) {
            val bounds = mapBounds ?: return@LaunchedEffect
            if (!fittedSelection && mapSize.width > 0 && mapSize.height > 0) {
                // Keep an already useful viewport: moving it starts another tile/render pass.
                val visible = cameraState.projection?.visibleRegion?.latLngBounds
                if (visible?.contains(bounds.southwest) == true && visible.contains(bounds.northeast)) {
                    fittedSelection = true
                    return@LaunchedEffect
                }
                val padding = minOf(100, minOf(mapSize.width, mapSize.height) / 4)
                cameraState.move(CameraUpdateFactory.newLatLngBounds(bounds, mapSize.width, mapSize.height, padding))
                fittedSelection = true
            }
        }
        selectedRoutes.forEach { key ->
            val routeColor = routes.firstOrNull { it.kml == key }?.color.toClr(AndroidColor.BLUE)
            traces[key]?.segments.orEmpty().forEachIndexed { index, points ->
                Polyline(points = points, color = Color.White.copy(alpha = .85f), width = 6f * density, zIndex = 0f)
                Polyline(
                    points = points,
                    color = Color(routeColor),
                    width = 3.5f * density,
                    zIndex = .5f,
                    tag = "$key-$index",
                )
            }
        }
    }
}
