package com.ryannair05.meetandeat.cata

import android.graphics.Color
import com.google.android.gms.maps.model.LatLng
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import com.squareup.moshi.Json
import retrofit2.http.GET
import retrofit2.http.Path
import retrofit2.http.Query

data class StopInfo(
    val name: String,
    val latLng: LatLng,
    val id: Int,
    val distanceMiles: Double? = null
)

data class BusInfo(
    val id: Int,
    val latLng: LatLng,
    val heading: Float,
    val routeId: Int,
    val dest: String?,
    val onBoard: Int,
    val capacity: Int,
    val routeColor: Int,
    val statusColor: androidx.compose.ui.graphics.Color
)

data class DepartureUi(
    val route: Int,
    val routeAbbreviation: String,
    val routeLongName: String,
    val dest: String,
    val etaText: String,
    val etaSort: Long,
    val color: Int,
    val textColor: Int,
    val status: String,
    val isLate: Boolean
)

@Serializable
data class RouteModel(
    @SerialName("RouteId") @Json(name = "RouteId") val routeId: Int,
    @SerialName("LongName") @Json(name = "LongName") val longName: String,
    @SerialName("RouteAbbreviation") @Json(name = "RouteAbbreviation") val abbr: String,
    @SerialName("TextColor") @Json(name = "TextColor") val textColor: String,
    @SerialName("Color") @Json(name = "Color") val color: String,
    @SerialName("RouteTraceFilename") @Json(name = "RouteTraceFilename") val kml: String,
    @SerialName("SortOrder") @Json(name = "SortOrder") val sort: Int,
)

data class RouteDetailsResponse(
    @Json(name = "Stops") val stops: List<StopJson>,
    @Json(name = "Vehicles") val vehicles: List<VehicleJson>,
)

data class RouteTrace(val segments: List<List<LatLng>>)

@Serializable
data class StopJson(
    @SerialName("Name") @Json(name = "Name") val name: String,
    @SerialName("Latitude") @Json(name = "Latitude") val lat: Double,
    @SerialName("Longitude") @Json(name = "Longitude") val lng: Double,
    @SerialName("StopId") @Json(name = "StopId") val id: Int,
)

data class VehicleJson(
    @Json(name = "VehicleId") val id: Int,
    @Json(name = "Latitude") val lat: Double,
    @Json(name = "Longitude") val lng: Double,
    @Json(name = "Heading") val heading: Double,
    @Json(name = "RouteId") val route: Int,
    @Json(name = "Destination") val dest: String?,
    @Json(name = "OnBoard") val onBoard: Int?,
    @Json(name = "SeatingCapacity") val capacity: Int?,
)

data class StopDeparturesWrapper(@Json(name = "RouteDirections") val dirs: List<RouteDirectionJson>?)
data class RouteDirectionJson(@Json(name = "RouteId") val route: Int, @Json(name = "Departures") val deps: List<DepartureJson>)
data class DepartureJson(
    @Json(name = "EDTLocalTime") val time: String,
    @Json(name = "Dev") val dev: String?,
    @Json(name = "Trip") val trip: TripJson
)
data class TripJson(
    @Json(name = "InternetServiceDesc") val dest: String,
    @Json(name = "TripStatusReportLabel") val status: String? = null,
)

// --- API ---

interface CataApi {
    @GET("InfoPoint/rest/Routes/GetVisibleRoutes")
    suspend fun routes(): List<RouteModel>

    @GET("InfoPoint/rest/RouteDetails/Get/{id}")
    suspend fun routeDetails(@Path("id") id: Int): RouteDetailsResponse

    @GET("InfoPoint/rest/Vehicles/GetAllVehiclesForRoutes")
    suspend fun vehicles(@Query("routeIDs") ids: String): List<VehicleJson>

    @GET("InfoPoint/rest/StopDepartures/Get/{stop}")
    suspend fun departures(@Path("stop") stop: Int): List<StopDeparturesWrapper>
}
