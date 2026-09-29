package com.ryannair05.meetandeat.cata

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.location.Location
import android.util.Log
import androidx.annotation.ColorInt
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.core.graphics.toColorInt
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.google.android.gms.location.LocationServices
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import kotlinx.coroutines.Job
import kotlinx.coroutines.suspendCancellableCoroutine
import com.ryannair05.meetandeat.dining.writeCacheAtomically
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import retrofit2.Retrofit
import retrofit2.converter.moshi.MoshiConverterFactory
import java.io.File
import java.time.Duration
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.nio.charset.StandardCharsets
import android.graphics.Color as AndroidColor

@ColorInt
internal fun String?.toClr(fallback: Int = AndroidColor.BLACK): Int = try {
    if (this.isNullOrBlank()) fallback else (if (startsWith("#")) this else "#$this").toColorInt()
} catch (_: Exception) { fallback }

internal fun parseCataDeviation(raw: String?): Long {
    if (raw.isNullOrBlank()) return 0
    val negative = raw.startsWith("-")
    val value = raw.removePrefix("-")
    val seconds = if (value.startsWith("PT")) {
        var total = 0L
        "(\\d+)([HMS])".toRegex().findAll(value.drop(2)).forEach {
            val amount = it.groupValues[1].toLong()
            total += when (it.groupValues[2]) { "H" -> amount * 3600; "M" -> amount * 60; else -> amount }
        }
        total
    } else {
        val parts = value.split(':').mapNotNull(String::toLongOrNull)
        if (parts.size == 3) parts[0] * 3600 + parts[1] * 60 + parts[2] else 0
    }
    return if (negative) -seconds else seconds
}

internal fun parseCataTrace(bytes: ByteArray): RouteTrace {
    val document = String(bytes, StandardCharsets.UTF_8)
    val coordinateBlocks = Regex(
        "<coordinates[^>]*>(.*?)</coordinates>",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
    )
    val segments = coordinateBlocks.findAll(document).mapNotNull { match ->
        val points = match.groupValues[1].trim().split(Regex("\\s+")).mapNotNull { tuple ->
            val values = tuple.split(',')
            val longitude = values.getOrNull(0)?.toDoubleOrNull() ?: return@mapNotNull null
            val latitude = values.getOrNull(1)?.toDoubleOrNull() ?: return@mapNotNull null
            LatLng(latitude, longitude)
        }
        points.takeIf { it.size >= 2 }
    }.toList()
    return RouteTrace(segments)
}

class MapVM(
    application: Application,
    apiProvider: () -> CataApi,
    clientProvider: () -> OkHttpClient,
) : AndroidViewModel(application) {
    private val api by lazy(apiProvider)

    private val startupStarted = android.os.SystemClock.elapsedRealtime()
    private val context: Context get() = getApplication<Application>().applicationContext
    private val prefs: SharedPreferences = context.getSharedPreferences("cata_prefs", Context.MODE_PRIVATE)
    private val client by lazy(clientProvider)
    private val fusedLocation = LocationServices.getFusedLocationProviderClient(context)
    private val cacheJson = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
    private val stopCacheDir = File(context.cacheDir, "cata/stops")
    private val catalog = CataRouteCatalog(File(context.cacheDir, "cata/visible-routes-v1.json")) { api.routes() }
    private val traceDir = File(context.cacheDir, "cata/traces")

    private val _selected = MutableStateFlow(prefs.getStringSet("selected", null)
        ?: setOf("Route51.kml", "Route55.kml", "Route57.kml"))
    val selected = _selected.asStateFlow()
    private val _routes = MutableStateFlow<List<RouteModel>>(emptyList())
    val routes = _routes.asStateFlow()
    private val _routeLoading = MutableStateFlow(true)
    val routeLoading = _routeLoading.asStateFlow()
    private val _routeError = MutableStateFlow<String?>(null)
    val routeError = _routeError.asStateFlow()
    private val _mapMessage = MutableStateFlow<String?>(null)
    val mapMessage = _mapMessage.asStateFlow()

    private val _stops = MutableStateFlow<Map<String, List<StopInfo>>>(emptyMap())
    val stops = _stops.asStateFlow()
    private val _buses = MutableStateFlow<Map<Int, BusInfo>>(emptyMap())
    val buses = _buses.asStateFlow()
    private val _selectedStop = MutableStateFlow<StopInfo?>(null)
    val selectedStop = _selectedStop.asStateFlow()
    private val _selectedBus = MutableStateFlow<BusInfo?>(null)
    val selectedBus = _selectedBus.asStateFlow()
    private val _deps = MutableStateFlow<List<DepartureUi>>(emptyList())
    val deps = _deps.asStateFlow()
    private val _departureLoading = MutableStateFlow(false)
    val loadingDepartures = _departureLoading.asStateFlow()
    private val _departureError = MutableStateFlow<String?>(null)
    val departureError = _departureError.asStateFlow()
    private val _mapBounds = MutableStateFlow<LatLngBounds?>(null)
    val mapBounds = _mapBounds.asStateFlow()
    private val _traces = MutableStateFlow<Map<String, RouteTrace>>(emptyMap())
    val traces = _traces.asStateFlow()
    private val _userLocation = MutableStateFlow<Location?>(null)
    val userLocation = _userLocation.asStateFlow()
    private val _screenActive = MutableStateFlow(false)
    private val _vehicleStatus = MutableStateFlow("Connecting to live buses…")
    val vehicleStatus = _vehicleStatus.asStateFlow()
    private val _vehiclesStale = MutableStateFlow(true)
    val vehiclesStale = _vehiclesStale.asStateFlow()
    private val routeRequests = mutableMapOf<String, Any>()
    private val routeLoads = SelectedRouteRequests(viewModelScope)
    private var catalogJob: Job? = null
    private var departureRequest: Job? = null
    private var departureGeneration = 0L
    private var lastVehicleUpdate: Instant? = null

    init {
        requestRoutes(false)
        viewModelScope.launch { updateUserLocation() }
        pollVehicles()
    }

    internal fun reportTiming(event: String) {
        if (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            Log.d("CataPerformance", "$event · ${android.os.SystemClock.elapsedRealtime() - startupStarted} ms since CATA start")
        }
    }

    fun setScreenActive(active: Boolean) {
        val entering = active && !_screenActive.value
        _screenActive.value = active
        if (entering) requestRoutes(false)
    }
    fun refreshRoutes() = requestRoutes(true)

    private fun requestRoutes(force: Boolean) {
        if (catalogJob?.isActive == true) return
        catalogJob = viewModelScope.launch { loadRoutes(force) }
    }
    fun updateLocationPermission() = viewModelScope.launch { updateUserLocation() }

    private suspend fun loadRoutes(force: Boolean) {
        _routeLoading.value = true
        _routeError.value = null
        _mapMessage.value = null
        try {
            var firstDelivery = true
            catalog.load(force) { loaded ->
                val previousIds = _routes.value.associate { it.kml to it.routeId }
                _routes.value = loaded
                reportTiming("Catalog ready (${loaded.size} routes)")
                reconcileSelection(loaded)
                loaded.filter { previousIds[it.kml]?.let { id -> id != it.routeId } == true }.forEach {
                    removeRoute(it.kml)
                }
                // This callback runs for saved routes before refresh, including an expired catalog.
                loadSelectedRoutes(force && firstDelivery)
                firstDelivery = false
            }
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) {
            _routeError.value = if (_routes.value.isEmpty()) "CATA routes couldn't be loaded. Check your connection."
                else "Showing saved routes · live refresh unavailable"
            Log.e("MapVM", "Route load failed", error)
        } finally {
            _routeLoading.value = false
        }
    }

    private fun reconcileSelection(routes: List<RouteModel>) {
        val byId = routes.associateBy(RouteModel::routeId)
        val selectedIds = _selected.value.mapNotNull { key ->
            Regex("Route(\\d+)").find(key)?.groupValues?.getOrNull(1)?.toIntOrNull()
        }.toSet()
        val reconciled = selectedIds.mapNotNull { byId[it]?.kml }.toSet()
        if (reconciled.isNotEmpty() && reconciled != _selected.value) {
            val removed = _selected.value - reconciled
            _selected.value = reconciled
            removed.forEach(::removeRoute)
            prefs.edit { putStringSet("selected", reconciled) }
        }
    }

    private fun loadSelectedRoutes(force: Boolean = false) {
        _selected.value.forEach { startRoute(it, force) }
    }

    private fun startRoute(key: String, force: Boolean = false) {
        val route = _routes.value.firstOrNull { it.kml == key } ?: return
        if (key !in _selected.value) return
        routeLoads.start(key, route.routeId, force) {
            loadTraceStops(key, force)
            key in _selected.value && _stops.value.containsKey(key) && _traces.value.containsKey(key)
        }
    }

    private suspend fun updateUserLocation() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        runCatching { fusedLocation.lastLocation.await() }.onSuccess { location ->
            _userLocation.value = location
            if (location != null) recomputeDistances(location)
        }
    }

    private fun recomputeDistances(location: Location) {
        _stops.update { all ->
            all.mapValues { (_, stops) -> stops.map { stop ->
                val target = Location("stop").apply { latitude = stop.latLng.latitude; longitude = stop.latLng.longitude }
                stop.copy(distanceMiles = location.distanceTo(target) * 0.000621371)
            } }
        }
    }

    fun toggle(key: String) {
        val next = _selected.value.toMutableSet()
        val added = if (!next.add(key)) { next.remove(key); false } else true
        _selected.value = next
        prefs.edit { putStringSet("selected", next) }
        if (added) startRoute(key) else removeRoute(key)
    }

    private suspend fun loadTraceStops(key: String, force: Boolean) = coroutineScope {
        if (key !in _selected.value) return@coroutineScope
        val route = _routes.value.firstOrNull { it.kml == key } ?: return@coroutineScope
        val request = Any()
        routeRequests[key] = request
        fun isCurrent() = key in _selected.value && routeRequests[key] === request
        fun publishStops(stops: List<StopJson>) {
            if (!isCurrent()) return
            val location = _userLocation.value
            _stops.update { old -> old + (key to stops.map { stop ->
                val target = Location("stop").apply { latitude = stop.lat; longitude = stop.lng }
                StopInfo(stop.name, LatLng(stop.lat, stop.lng), stop.id, location?.distanceTo(target)?.times(0.000621371))
            }) }
            // Stops can frame the map immediately; a slow trace download must not delay it.
            updateMapBounds()
        }
        val details = launch {
            val stopFile = File(stopCacheDir, "${route.routeId}.json")
            val (cachedStops, stopsFresh) = withContext(Dispatchers.IO) {
                runCatching { cacheJson.decodeFromString<List<StopJson>>(stopFile.readText()) }.getOrNull() to
                    isCataGeometryFresh(stopFile.lastModified(), System.currentTimeMillis())
            }
            if (!isCurrent()) return@launch
            if (!cachedStops.isNullOrEmpty()) {
                publishStops(cachedStops)
                reportTiming("Saved stops ready for ${route.routeId} (${cachedStops.size})")
                if (!force && stopsFresh) return@launch
            }
            runCatching { withContext(Dispatchers.IO) { api.routeDetails(route.routeId) } }
                .onSuccess { response ->
                    if (!isCurrent()) return@onSuccess
                    publishStops(response.stops)
                    reportTiming("Live stops ready for ${route.routeId} (${response.stops.size})")
                    mergeVehicles(response.vehicles, replace = false)
                    withContext(Dispatchers.IO) {
                        runCatching {
                            writeCacheAtomically(stopFile, cacheJson.encodeToString(kotlinx.serialization.builtins.ListSerializer(StopJson.serializer()), response.stops).toByteArray())
                        }
                    }
                }.onFailure {
                    if (it is CancellationException) throw it
                    if (isCurrent()) _mapMessage.value = if (cachedStops.isNullOrEmpty())
                        "Some route stops are temporarily unavailable" else "Showing saved stops · live refresh unavailable"
                    Log.w("MapVM", "Stops unavailable for route ${route.routeId}", it)
                }
        }
        val trace = launch {
            val file = File(traceDir, key)
            val (cached, traceFresh) = withContext(Dispatchers.IO) {
                runCatching { parseCataTrace(file.readBytes()) }.getOrNull() to
                    isCataGeometryFresh(file.lastModified(), System.currentTimeMillis())
            }
            if (!isCurrent()) return@launch
            if (cached != null && cached.segments.isNotEmpty()) {
                _traces.update { it + (key to cached) }
                updateMapBounds()
                if (!force && traceFresh) return@launch
            }
            try {
                val parsed = withContext(Dispatchers.IO) {
                    val bytes = client.newCall(Request.Builder().url("https://realtime.catabus.com/InfoPoint/Resources/Traces/$key").build())
                        .awaitTraceBytes()
                    val parsed = parseCataTrace(bytes)
                    require(parsed.segments.isNotEmpty()) { "Empty route geometry" }
                    runCatching { writeCacheAtomically(file, bytes) }

                    parsed
                }
                if (isCurrent()) {
                    _traces.update { it + (key to parsed) }
                    updateMapBounds()
                }
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) {
                if (isCurrent() && cached == null) _mapMessage.value = "Some route lines couldn't be drawn"
            }
        }
        details.join(); trace.join()
        if (isCurrent()) updateMapBounds()
    }

    private fun removeRoute(key: String) {
        routeRequests.remove(key)
        routeLoads.cancel(key)
        _stops.update { it - key }
        val selectedIds = selectedRouteIds()
        _buses.update { current -> current.filterValues { it.routeId in selectedIds } }
        _traces.update { it - key }
        if (_selectedBus.value?.routeId?.let { it !in selectedIds } == true ||
            _selectedStop.value?.let { selected -> _stops.value.values.none { stops -> stops.any { it.id == selected.id } } } == true) {
            clearSelection()
        }
        updateMapBounds()
    }

    private fun mergeVehicles(list: List<VehicleJson>, replace: Boolean) {
        val routes = _routes.value.associateBy(RouteModel::routeId)
        val selectedIds = selectedRouteIds()
        val mapped = list.mapNotNull { vehicle ->
            if (vehicle.route !in selectedIds) return@mapNotNull null
            if (vehicle.lat == 0.0 || vehicle.lng == 0.0) return@mapNotNull null
            val capacity = vehicle.capacity ?: 40
            val onboard = vehicle.onBoard ?: 0
            val ratio = if (capacity > 0) onboard.toFloat() / capacity else 0f
            vehicle.id to BusInfo(
                vehicle.id, LatLng(vehicle.lat, vehicle.lng), vehicle.heading.toFloat(), vehicle.route,
                vehicle.dest, onboard, capacity, routes[vehicle.route]?.color.toClr(AndroidColor.BLUE),
                when { ratio >= .9f -> androidx.compose.ui.graphics.Color(0xFFB3261E); ratio >= .5f -> androidx.compose.ui.graphics.Color(0xFFF9A825); else -> androidx.compose.ui.graphics.Color(0xFF2E7D32) },
            )
        }.toMap()
        _buses.update { current -> if (replace) mapped else current + mapped }
        _selectedBus.update { selected -> selected?.let { mapped[it.id] ?: if (replace) null else it } }
    }

    private fun pollVehicles() = viewModelScope.launch {
        var lastRoutes: Set<Int>? = null
        combine(_screenActive, _selected, _routes) { active, _, _ -> active to selectedRouteIds() }
            .distinctUntilChanged()
            .collectLatest { (active, ids) ->
                if (!active) return@collectLatest
                if (lastRoutes != ids) { lastVehicleUpdate = null; lastRoutes = ids }
                // A tab switch is not a failed update. Retain fresh markers while refreshing.
                val ageMillis = lastVehicleUpdate?.let { Duration.between(it, Instant.now()).toMillis() }
                _vehiclesStale.value = _vehiclesStale.value || ageMillis == null || ageMillis !in 0 until 15_000L
                if (ids.isEmpty()) _vehicleStatus.value = "No routes selected"
                else if (_vehiclesStale.value) _vehicleStatus.value = "Updating bus positions…"
                if (ids.isEmpty()) { _buses.value = emptyMap(); return@collectLatest }
                while (isActive) {
                    try {
                        val vehicles = withContext(Dispatchers.IO) { api.vehicles(ids.joinToString(",")) }
                        mergeVehicles(vehicles, replace = true)
                        lastVehicleUpdate = Instant.now()
                        _vehiclesStale.value = false
                        _vehicleStatus.value = context.resources.getQuantityString(
                            com.ryannair05.meetandeat.R.plurals.cata_bus_count, _buses.value.size, _buses.value.size)
                    } catch (error: CancellationException) { throw error }
                    catch (_: Exception) {
                        _vehiclesStale.value = true
                        val updated = lastVehicleUpdate?.atZone(CATA_ZONE)?.format(DateTimeFormatter.ofPattern("h:mm a"))
                        _vehicleStatus.value = updated?.let { "Reconnecting · Last updated $it" }
                            ?: "Live bus positions unavailable · Retrying…"
                    }
                    delay(3_500)
                }
            }
    }

    private fun selectedRouteIds() = _selected.value.mapNotNull { key -> _routes.value.firstOrNull { it.kml == key }?.routeId }.toSet()

    fun selectStop(stop: StopInfo) {
        _selectedBus.value = null
        if (_selectedStop.value?.id != stop.id) _deps.value = emptyList()
        _selectedStop.value = stop
        loadDepartures(stop)
    }
    fun selectBus(bus: BusInfo) { clearSelection(); _selectedBus.value = bus }
    fun clearSelection() {
        departureGeneration++
        departureRequest?.cancel()
        departureRequest = null
        _departureLoading.value = false
        _selectedStop.value = null
        _selectedBus.value = null
        _deps.value = emptyList()
        _departureError.value = null
    }
    fun refreshDepartures() { _selectedStop.value?.let(::loadDepartures) }

    private fun loadDepartures(stop: StopInfo) {
        val generation = ++departureGeneration
        departureRequest?.cancel()
        departureRequest = viewModelScope.launch {
            fun isCurrent() = generation == departureGeneration && _selectedStop.value?.id == stop.id
            _departureLoading.value = true
            _departureError.value = null
            val routes = _routes.value.associateBy(RouteModel::routeId)
            runCatching { withContext(Dispatchers.IO) { api.departures(stop.id) } }.onSuccess { wrappers ->
                if (!isCurrent()) return@onSuccess
                val now = Instant.now()
                _deps.value = wrappers.firstOrNull()?.dirs.orEmpty().flatMap { direction ->
                    direction.deps.mapNotNull { departure ->
                        runCatching {
                            val scheduled = LocalDateTime.parse(departure.time, DateTimeFormatter.ISO_LOCAL_DATE_TIME)
                                .atZone(CATA_ZONE).plusSeconds(parseCataDeviation(departure.dev)).toInstant()
                            val seconds = Duration.between(now, scheduled).seconds
                            val status = departure.trip.status ?: "Scheduled"
                            val text = when {
                                status != "Scheduled" -> status
                                seconds < -30 -> "Late"
                                seconds < 60 -> "Now"
                                seconds < 3600 -> "${maxOf(1, seconds / 60)} min"
                                else -> scheduled.atZone(CATA_ZONE).format(DateTimeFormatter.ofPattern("h:mm a"))
                            }
                            val route = routes[direction.route]
                            DepartureUi(
                                direction.route, route?.abbr ?: direction.route.toString(),
                                route?.longName ?: "Route ${direction.route}", departure.trip.dest.ifBlank { "Upcoming departure" },
                                text, scheduled.toEpochMilli(), route?.color.toClr(AndroidColor.GRAY),
                                route?.textColor.toClr(contrastText(route?.color.toClr(AndroidColor.GRAY))), status,
                                text == "Late",
                            )
                        }.getOrNull()
                    }
                }.sortedBy(DepartureUi::etaSort)
            }.onFailure {
                if (it is CancellationException) throw it
                if (isCurrent()) _departureError.value = "Upcoming departures couldn't be loaded."
            }
            if (isCurrent()) _departureLoading.value = false
        }
    }

    private fun updateMapBounds() {
        val points = _stops.value.values.flatten().map { it.latLng } + _traces.value.values.flatMap { it.segments.flatten() }
        if (points.isEmpty()) { _mapBounds.value = null; return }
        runCatching { LatLngBounds.Builder().apply { points.forEach { include(it) } }.build() }
            .onSuccess { _mapBounds.value = it }
    }

    private fun contrastText(background: Int): Int {
        val luminance = (.2126 * AndroidColor.red(background) + .7152 * AndroidColor.green(background) + .0722 * AndroidColor.blue(background)) / 255
        return if (luminance > .48) AndroidColor.BLACK else AndroidColor.WHITE
    }

    companion object { private val CATA_ZONE = ZoneId.of("America/New_York") }
}

class VMFactory(private val app: Application) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        // Construct the shared transport on its first IO request, not during screen composition.
        val client by lazy { OkHttpClient() }
        val api by lazy {
            val moshi = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build()
            Retrofit.Builder().baseUrl("https://realtime.catabus.com/").client(client)
                .addConverterFactory(MoshiConverterFactory.create(moshi)).build().create(CataApi::class.java)
        }
        @Suppress("UNCHECKED_CAST") return MapVM(app, { api }, { client }) as T
    }
}

/** Cancelling a deselected route also cancels its socket, rather than just ignoring its result. */
private suspend fun okhttp3.Call.awaitTraceBytes(): ByteArray = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : okhttp3.Callback {
        override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
            continuation.resumeWith(Result.failure(e))
        }
        override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
            val result = runCatching {
                response.use {
                    if (!it.isSuccessful) error("Trace HTTP ${it.code}")
                    it.body?.bytes() ?: error("Empty route trace")
                }
            }
            continuation.resumeWith(result)
        }
    })
}
