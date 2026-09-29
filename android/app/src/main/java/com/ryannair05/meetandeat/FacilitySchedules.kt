package com.ryannair05.meetandeat

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.jsoup.Jsoup
import java.time.*
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/** The same parent facilities and seven-day campus-local window used by the iOS app. */
internal object FacilitySchedules {
    private const val ENDPOINT = "https://pennstatecampusrec.org/Facility/GetScheduleCustomAppointmentsForDevExtremeScheduler"
    private val campusZone = ZoneId.of("America/New_York")
    private val sources = linkedMapOf(
        "Gym 1" to "71108e9a-c220-474b-9fb0-0376e847f6b9",
        "Gym 2" to "6556d93f-ed79-4398-9fad-d7c2b58af2d7",
        "Gym 3" to "38aec95d-e2f6-46ed-a2b1-36cb194bce6d",
        "Gym 4" to "cc2490cc-b871-4209-a2db-47a2969edf0e",
        "Turf East" to "beeb7f84-8171-4ce0-ab09-665db211f201",
        "Turf West" to "c8424f80-8962-4fd2-b6a4-5e6f9d0e843d",
    )
    data class Loaded(val schedules: List<ActivitySchedule>, val incomplete: Boolean)
    internal data class Occurrence(val activity: String, val location: String, val day: Int, val time: String)

    suspend fun load(): Loaded = withContext(Dispatchers.IO) {
        val start = LocalDate.now(campusZone)
        val results = coroutineScope {
            sources.map { (location, id) -> async {
                runCatching {
                    val response = Jsoup.connect(ENDPOINT).ignoreContentType(true).timeout(20_000)
                        .data("selectedFacilityId", id)
                        .data("start", start.atStartOfDay().format(DateTimeFormatter.ISO_LOCAL_DATE_TIME))
                        .data("end", start.plusDays(6).atTime(23, 59, 59).format(DateTimeFormatter.ISO_LOCAL_DATE_TIME))
                        .execute()
                    check(response.contentType()?.contains("application/json", true) == true) { "Unexpected facility response" }
                    val array = JSONArray(response.body())
                    val appointments = (0 until array.length()).map { index ->
                        val item = array.getJSONObject(index)
                        Appointment(item.getString("Text"), item.getString("StartDate"), item.getString("EndDate"),
                            item.optBoolean("AllDay"), item.optString("RecurrenceRule"), item.optString("RecurrenceException"))
                    }
                    occurrences(appointments, location, start)
                }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }
            } }.awaitAll()
        }
        check(results.any { it.isSuccess }) { "Facility schedules are temporarily unavailable." }
        val occurrences = results.flatMap { it.getOrNull().orEmpty() }
        val headers = listOf("Facility") + (0L..6L).map { start.plusDays(it).format(DateTimeFormatter.ofPattern("EEE M/d", Locale.US)) }
        Loaded(occurrences.groupBy { it.activity }.toSortedMap().map { (activity, entries) ->
            ActivitySchedule(id = activity, activity = activity, tables = listOf(ScheduleTable(
                headers = headers,
                rows = entries.groupBy { it.location }.toSortedMap().map { (location, times) ->
                    ScheduleRow(cells = listOf(location) + (0..6).map { day ->
                        times.filter { it.day == day }.map { it.time }.distinct().sorted().joinToString("\n")
                    })
                }
            )))
        }, incomplete = results.any { it.isFailure })
    }

    internal data class Appointment(
        val text: String, val startDate: String, val endDate: String, val allDay: Boolean = false,
        val recurrenceRule: String = "", val recurrenceException: String = "",
    )

    internal fun occurrences(appointments: List<Appointment>, location: String, start: LocalDate): List<Occurrence> = buildList {
        val timeFormat = DateTimeFormatter.ofPattern("h:mm a", Locale.US)
        val compact = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss")
        for (appointment in appointments) {
            val begins = LocalDateTime.parse(appointment.startDate)
            val ends = LocalDateTime.parse(appointment.endDate)
            val activity = appointment.text.trim()
            val time = if (appointment.allDay) "All Day" else "${begins.format(timeFormat)}–${ends.format(timeFormat)}"
            val rule = appointment.recurrenceRule.takeUnless { it == "null" }.orEmpty()
            val days = if (rule.isBlank()) listOf(begins.toLocalDate()) else {
                val parts = rule.split(';').mapNotNull { part ->
                    part.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] }
                }.toMap()
                if (parts["FREQ"] != "WEEKLY") continue
                val weekdays = parts["BYDAY"].orEmpty().split(',')
                val abbreviations = listOf("MO", "TU", "WE", "TH", "FR", "SA", "SU")
                val until = parts["UNTIL"]?.let { value ->
                    if (value.endsWith('Z')) LocalDateTime.parse(value.dropLast(1), compact).toInstant(ZoneOffset.UTC)
                    else LocalDateTime.parse(value, compact).atZone(campusZone).toInstant()
                }
                val exceptions = appointment.recurrenceException.split(',').filter { it.isNotBlank() && it != "null" }.map { value ->
                    if (value.endsWith('Z')) LocalDateTime.parse(value.dropLast(1), compact).toInstant(ZoneOffset.UTC)
                    else LocalDateTime.parse(value, compact).atZone(campusZone).toInstant()
                }.toSet()
                val interval = parts["INTERVAL"]?.toLongOrNull()?.coerceAtLeast(1) ?: 1L
                (0L..6L).map { start.plusDays(it) }.filter { day ->
                    val occurrence = day.atTime(begins.toLocalTime())
                    val instant = occurrence.atZone(campusZone).toInstant()
                    val weekStart = begins.toLocalDate().with(java.time.temporal.TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
                    abbreviations[day.dayOfWeek.value - 1] in weekdays && occurrence >= begins &&
                        ChronoUnit.WEEKS.between(weekStart, day) % interval == 0L &&
                        (until == null || instant <= until) && instant !in exceptions
                }
            }
            days.forEach { day ->
                val index = ChronoUnit.DAYS.between(start, day).toInt()
                if (index in 0..6) add(Occurrence(activity, location, index, time))
            }
        }
    }
}
