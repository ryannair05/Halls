package com.ryannair05.meetandeat.cata

import android.animation.ValueAnimator
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import androidx.core.graphics.ColorUtils
import android.view.animation.DecelerateInterpolator
import androidx.core.content.ContextCompat
import androidx.core.graphics.createBitmap
import com.google.android.gms.maps.GoogleMap
import com.google.android.gms.maps.model.BitmapDescriptor
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.Marker
import com.google.android.gms.maps.model.MarkerOptions
import com.ryannair05.meetandeat.R
import kotlin.math.roundToInt
import android.graphics.Color as AndroidColor

/** Keeps rapidly changing CATA annotations out of the Compose tree. */
@SuppressLint("PotentialBehaviorOverride") // Owns all bus and stop marker clicks.
internal class CataMarkerController(
    private val context: Context,
    private val onStopClick: (StopInfo) -> Unit,
    private val onBusClick: (BusInfo) -> Unit,
) {
    private sealed interface MarkerTag {
        data class Stop(val id: Int) : MarkerTag
        data class Bus(val id: Int) : MarkerTag
    }

    private var map: GoogleMap? = null
    private var currentStops: Map<Int, StopInfo> = emptyMap()
    private var staleBuses = false
    private var currentBuses: Map<Int, BusInfo> = emptyMap()
    private var renderedStops: Map<Int, StopInfo> = emptyMap()
    private var renderedBuses: Map<Int, BusInfo> = emptyMap()
    private val stopMarkers = mutableMapOf<Int, Marker>()
    private val busMarkers = mutableMapOf<Int, Marker>()
    private val busAnimators = mutableMapOf<Int, ValueAnimator>()
    private val busIcons = mutableMapOf<Pair<Int, Boolean>, BitmapDescriptor>()
    private val appliedBusIcons = mutableMapOf<Int, Pair<Int, Boolean>>()
    private var selectedBusId: Int? = null
    private val stopIcon by lazy { createStopBitmap(context) }

    fun attach(newMap: GoogleMap) {
        if (map === newMap) return
        detach()
        map = newMap
        claimMarkerClicks()
        renderStops()
        renderBuses(animate = false)
        busMarkers.values.forEach { it.alpha = if (staleBuses) 0.55f else 1f }
    }

    fun claimMarkerClicks() {
        map?.setOnMarkerClickListener(::onMarkerClick)
    }

    fun updateStops(stops: Collection<StopInfo>) {
        currentStops = stops.associateBy(StopInfo::id)
        renderStops()
    }

    fun updateBuses(buses: Collection<BusInfo>, stale: Boolean) {
        val next = buses.associateBy(BusInfo::id)
        if (currentBuses == next && staleBuses == stale) return
        val staleChanged = staleBuses != stale
        staleBuses = stale
        currentBuses = next
        renderBuses(animate = !stale)
        if (staleChanged) {
            busMarkers.values.forEach { it.alpha = if (stale) 0.55f else 1f }
            if (stale) {
                busAnimators.values.toList().forEach(ValueAnimator::cancel)
                busAnimators.clear()
            }
        }
    }

    fun selectBus(id: Int?) {
        if (selectedBusId == id) return
        selectedBusId = id
        renderBuses(animate = false)
    }

    fun detach() {
        map?.setOnMarkerClickListener(null)
        busAnimators.values.toList().forEach(ValueAnimator::cancel)
        busAnimators.clear()
        stopMarkers.values.forEach(Marker::remove)
        stopMarkers.clear()
        busMarkers.values.forEach(Marker::remove)
        busMarkers.clear()
        appliedBusIcons.clear()
        renderedStops = emptyMap()
        renderedBuses = emptyMap()
        map = null
    }

    private fun renderStops() {
        val activeMap = map ?: return
        (stopMarkers.keys - currentStops.keys).forEach { id -> stopMarkers.remove(id)?.remove() }
        currentStops.forEach { (id, stop) ->
            val marker = stopMarkers[id]
            if (marker == null) {
                stopMarkers[id] = activeMap.addMarker(
                    MarkerOptions()
                        .position(stop.latLng)
                        .anchor(.5f, .5f)
                        .icon(stopIcon)
                        .title(stop.name)
                        .zIndex(1f)
                )?.also { it.tag = MarkerTag.Stop(id) } ?: return@forEach
            } else {
                val previous = renderedStops[id]
                if (previous?.latLng != stop.latLng) marker.position = stop.latLng
                if (previous?.name != stop.name) marker.title = stop.name
            }
        }
        renderedStops = currentStops
    }

    private fun renderBuses(animate: Boolean) {
        val activeMap = map ?: return
        (busMarkers.keys - currentBuses.keys).forEach { id ->
            busAnimators.remove(id)?.cancel()
            busMarkers.remove(id)?.remove()
            appliedBusIcons.remove(id)
        }
        currentBuses.forEach { (id, bus) ->
            val existing = busMarkers[id]
            if (existing == null) {
                busMarkers[id] = activeMap.addMarker(
                    MarkerOptions()
                        .position(bus.latLng)
                        .anchor(.5f, 1f)
                        .icon(busIcon(bus))
                        .title(bus.dest ?: "Bus ${bus.id}")
                        .snippet(bus.snippet())
                        .alpha(if (staleBuses) 0.55f else 1f)
                        .zIndex(if (id == selectedBusId) 5f else 2f)
                )?.also {
                    it.tag = MarkerTag.Bus(id)
                    appliedBusIcons[id] = bus.routeColor to (id == selectedBusId)
                } ?: return@forEach
            } else {
                val previous = renderedBuses[id]
                if (previous?.dest != bus.dest) existing.title = bus.dest ?: "Bus ${bus.id}"
                if (previous?.routeId != bus.routeId || previous.onBoard != bus.onBoard || previous.capacity != bus.capacity) {
                    existing.snippet = bus.snippet()
                }
                val iconKey = bus.routeColor to (id == selectedBusId)
                if (appliedBusIcons[id] != iconKey) {
                    existing.setIcon(busIcon(bus))
                    appliedBusIcons[id] = iconKey
                    existing.zIndex = if (id == selectedBusId) 5f else 2f
                }
                if (previous?.latLng != bus.latLng) {
                    if (animate && ValueAnimator.areAnimatorsEnabled()) animateBus(existing, bus) else {
                        busAnimators.remove(id)?.cancel()
                        existing.position = bus.latLng
                    }
                }
            }
        }
        renderedBuses = currentBuses
    }

    private fun busIcon(bus: BusInfo) = busIcons.getOrPut(bus.routeColor to (bus.id == selectedBusId)) {
        createBusBitmap(context, bus.routeColor, bus.id == selectedBusId)
    }

    private fun animateBus(marker: Marker, bus: BusInfo) {
        val start = marker.position
        val end = bus.latLng
        if (start == end) return
        busAnimators.remove(bus.id)?.cancel()
        busAnimators[bus.id] = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 750L
            interpolator = DecelerateInterpolator()
            var lastFrameTime = -33L
            addUpdateListener { animation ->
                // Native marker changes trigger map rendering. Bound interpolation to 30 updates/sec.
                if (animation.currentPlayTime - lastFrameTime < 33 && animation.animatedFraction < 1f) return@addUpdateListener
                lastFrameTime = animation.currentPlayTime
                val fraction = animation.animatedFraction.toDouble()
                marker.position = LatLng(
                    start.latitude + (end.latitude - start.latitude) * fraction,
                    start.longitude + (end.longitude - start.longitude) * fraction,
                )

            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (busAnimators[bus.id] === animation) busAnimators.remove(bus.id)
                }
            })
            start()
        }
    }

    private fun onMarkerClick(marker: Marker): Boolean = when (val tag = marker.tag) {
        is MarkerTag.Stop -> currentStops[tag.id]?.let { onStopClick(it); true } ?: false
        is MarkerTag.Bus -> currentBuses[tag.id]?.let { selectBus(it.id); onBusClick(it); true } ?: false
        else -> false
    }

    private fun BusInfo.snippet() = "Route $routeId · $onBoard/$capacity passengers"
}

private fun createStopBitmap(context: Context): BitmapDescriptor {
    val density = context.resources.displayMetrics.density
    // Keep stops readable without a large transparent texture obscuring nearby map taps.
    val size = (16f * density).roundToInt()
    val visibleDiameter = (11f * density).roundToInt()
    val bitmap = createBitmap(size, size)
    val canvas = Canvas(bitmap)
    val center = size / 2f
    val radius = visibleDiameter / 2f
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    paint.color = AndroidColor.WHITE
    canvas.drawCircle(center, center, radius, paint)
    paint.style = Paint.Style.STROKE
    paint.strokeWidth = (1.5f * density).coerceAtLeast(2f)
    paint.color = AndroidColor.DKGRAY
    canvas.drawCircle(center, center, radius - paint.strokeWidth / 2f, paint)
    return BitmapDescriptorFactory.fromBitmap(bitmap)
}

/** Route identity stays fixed; a dark inset protects the white glyph on light routes. */
private fun createBusBitmap(context: Context, color: Int, selected: Boolean): BitmapDescriptor {
    val density = context.resources.displayMetrics.density
    val markerScale = (if (selected) 38f else 32f) / 48f
    val width = 48f
    val height = width + 8f
    val bitmap = createBitmap((width * density * markerScale).roundToInt(), (height * density * markerScale).roundToInt())
    val canvas = Canvas(bitmap).apply { scale(density * markerScale, density * markerScale) }
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    val center = width / 2f
    val body = RectF(3f, 3f, width - 3f, width - 3f)
    val pointer = Path().apply { moveTo(center - 9f, width - 6f); lineTo(center, height - 2f); lineTo(center + 9f, width - 6f); close() }
    paint.color = color
    paint.setShadowLayer(2f, 0f, 1f, 0x66000000)
    canvas.drawPath(pointer, paint)
    canvas.drawRoundRect(body, 16f, 16f, paint)
    paint.clearShadowLayer()
    paint.style = Paint.Style.STROKE
    paint.strokeWidth = if (selected) 3f else 1.5f
    paint.color = AndroidColor.WHITE
    canvas.drawRoundRect(body, 16f, 16f, paint)
    paint.style = Paint.Style.FILL
    if (ColorUtils.calculateContrast(AndroidColor.WHITE, color) < 3.0) {
        paint.color = 0xFF263238.toInt()
        canvas.drawRoundRect(RectF(center - 15f, center - 15f, center + 15f, center + 15f), 9f, 9f, paint)
    }
    ContextCompat.getDrawable(context, R.drawable.symbol_directions_bus_fill1)?.mutate()?.let { drawable ->
        drawable.setTint(AndroidColor.WHITE)
        drawable.setBounds((center - 12).roundToInt(), (center - 12).roundToInt(), (center + 12).roundToInt(), (center + 12).roundToInt())
        drawable.draw(canvas)
    }
    return BitmapDescriptorFactory.fromBitmap(bitmap)
}
