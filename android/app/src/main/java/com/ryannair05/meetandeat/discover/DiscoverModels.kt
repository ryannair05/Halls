package com.ryannair05.meetandeat.discover

import androidx.annotation.Keep
import org.jsoup.Jsoup
import java.net.URI
import java.text.Normalizer
import java.time.*
import java.time.temporal.TemporalAdjusters
import java.util.Locale

internal object DiscoverSource {
    val zone: ZoneId = ZoneId.of("America/New_York")
    fun normalized(value: String) = Normalizer.normalize(value, Normalizer.Form.NFD)
        .replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT).trim().replace(Regex("\\s+"), " ")
    // Engage occasionally publishes isolated UTF-16 surrogates. Keep disk round trips stable.
    fun cleanText(value: String): String = buildString {
        value.codePoints().forEach { appendCodePoint(if (it in 0xD800..0xDFFF) 0xFFFD else it) }
    }
    fun plain(html: String?): String = cleanText(Jsoup.parseBodyFragment(html.orEmpty()).apply { select("script,style").remove() }.text())
    fun https(value: String?): String? = value?.takeIf {
        runCatching { URI(it).let { u -> u.scheme == "https" && !u.host.isNullOrBlank() && u.userInfo == null } }.getOrDefault(false)
    }
    fun image(value: String?, poster: Boolean = false): String? {
        https(value)?.let { return it }
        if (value == null || !Regex("[A-Za-z0-9_.-]+\\.(?i:jpg|jpeg|png|webp|gif)").matches(value)) return null
        return "https://se-images.campuslabs.com/clink/images/$value?" +
            if (poster) "width=1000&height=1000&mode=max&format=jpg&quality=85" else "preset=med-sq"
    }
    fun online(html: String?): String? = Jsoup.parseBodyFragment(html.orEmpty(), "https://discover.psu.edu")
        .select("a[href]").firstNotNullOfOrNull { anchor ->
            https(anchor.absUrl("href"))?.takeIf { url ->
                val host = URI(url).host.lowercase(Locale.ROOT)
                listOf("zoom.us", "teams.microsoft.com", "teams.live.com", "meet.google.com", "webex.com")
                    .any { host == it || host.endsWith(".$it") } || normalized(anchor.text()) in setOf("join online", "join meeting", "online event")
            }
        }
    fun eventId(url: String?, uid: String): String = runCatching {
        val uri = URI(url.orEmpty())
        if (uri.host == "discover.psu.edu" && Regex("/event/[^/]+").matches(uri.path)) uri.path.substringAfterLast('/') else "ical:$uid"
    }.getOrDefault("ical:$uid")
}

@Keep internal data class CampusOrganization(
    val id: String, val name: String, val summary: String = "", val description: String = "",
    val categories: List<String> = emptyList(), val officialUrl: String? = null, val imageUrl: String? = null,
)
@Keep internal enum class EventSource { JSON, CALENDAR }
@Keep internal data class CampusEvent(
    val id: String, val title: String, val start: Long, val end: Long? = null,
    val description: String = "", val allDay: Boolean = false, val location: String = "",
    val hostNames: List<String> = emptyList(), val organizationIds: List<String> = emptyList(),
    val categories: List<String> = emptyList(), val benefits: List<String> = emptyList(),
    val officialUrl: String? = null, val imageUrl: String? = null, val organizationImageUrl: String? = null,
    val latitude: Double? = null, val longitude: Double? = null, val source: EventSource = EventSource.JSON,
    val cancelled: Boolean = false, val onlineUrl: String? = null,
) {
    val startTime: ZonedDateTime get() = Instant.ofEpochMilli(start).atZone(DiscoverSource.zone)
    val effectiveEnd: Long get() = end ?: if (allDay) startTime.plusDays(1).toInstant().toEpochMilli() else start
    val online: Boolean get() = onlineUrl != null || DiscoverSource.normalized(location).contains("online") || categories.any { DiscoverSource.normalized(it).contains("virtual") }
    fun upcoming(now: Long) = if (end != null || allDay) effectiveEnd > now else start >= now
    fun ongoing(now: Long): Boolean {
        val last = Instant.ofEpochMilli(if (allDay) effectiveEnd - 1 else effectiveEnd).atZone(DiscoverSource.zone).toLocalDate()
        val today = Instant.ofEpochMilli(now).atZone(DiscoverSource.zone).toLocalDate()
        return last != startTime.toLocalDate() && startTime.toLocalDate() < today && upcoming(now)
    }
}
@Keep internal data class DiscoverSnapshot(
    val organizations: List<CampusOrganization> = emptyList(), val events: List<CampusEvent> = emptyList(),
    val organizationsUpdated: Long? = null, val eventsUpdated: Long? = null,
    val directoryComplete: Boolean = false, val eventSource: EventSource? = null,
)
@Keep internal data class DiscoverSaved(
    val version: Int = 1, val organizations: Map<String, CampusOrganization> = emptyMap(),
    val events: Map<String, CampusEvent> = emptyMap(),
) {
    fun merge(snapshot: DiscoverSnapshot) = copy(
        organizations = organizations + snapshot.organizations.filter { it.id in organizations }.associateBy { it.id },
        events = events + snapshot.events.filter { it.id in events }.associateBy { it.id },
    )
}
@Keep internal enum class DiscoverDate(val label: String) {
    TODAY("Today"), TOMORROW("Tomorrow"), WEEK("This Week"), UPCOMING("All Upcoming");
    fun includes(event: CampusEvent, now: Long): Boolean {
        val date = Instant.ofEpochMilli(now).atZone(DiscoverSource.zone).toLocalDate()
        fun millis(d: LocalDate) = d.atStartOfDay(DiscoverSource.zone).toInstant().toEpochMilli()
        val start = if (this == TOMORROW) millis(date.plusDays(1)) else if (this == UPCOMING) now else millis(date)
        val end = when (this) {
            TODAY -> millis(date.plusDays(1))
            TOMORROW -> millis(date.plusDays(2))
            WEEK -> millis(date.with(TemporalAdjusters.next(DayOfWeek.SUNDAY)))
            UPCOMING -> null
        }
        return event.upcoming(maxOf(start, now)) && (end == null || event.start < end)
    }
}
@Keep internal data class DiscoverFilters(
    val homeDate: DiscoverDate = DiscoverDate.TODAY, val date: DiscoverDate = DiscoverDate.WEEK,
    val eventQuery: String = "", val clubQuery: String = "", val eventCategory: String = "", val clubCategory: String = "",
    val freeFood: Boolean = false, val onlineOnly: Boolean = false, val savedClubsOnly: Boolean = false,
)
internal fun classifyCampus(events: List<CampusEvent>, clubs: List<CampusOrganization>): List<CampusEvent> {
    val ids = clubs.map { it.id }.toSet()
    val names = clubs.groupBy { DiscoverSource.normalized(it.name) }
    return events.mapNotNull { event ->
        if (event.source == EventSource.JSON) event.takeIf { it.organizationIds.any(ids::contains) }
        else {
            val matches = event.hostNames.flatMap { names[DiscoverSource.normalized(it)].orEmpty() }.map { it.id }.distinct()
            val location = DiscoverSource.normalized(event.location)
            when {
                matches.isNotEmpty() -> event.copy(organizationIds = matches)
                location.contains("university park") || location.contains("state college") || event.categories.any { DiscoverSource.normalized(it).contains("university park") } -> event
                else -> null
            }
        }
    }
}
