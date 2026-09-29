package com.ryannair05.meetandeat.discover

import com.squareup.moshi.Moshi
import java.time.*
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle

internal data class DiscoverPage(val count: Int, val records: List<Map<String, Any?>>)
internal object DiscoverJson {
    private val adapter = Moshi.Builder().build().adapter(Any::class.java)
    @Suppress("UNCHECKED_CAST")
    fun page(text: String): DiscoverPage {
        val root = adapter.fromJson(text) as? Map<String, Any?> ?: error("Unreadable Discover response")
        val count = (root["@odata.count"] as? Number)?.toInt()?.takeIf { it >= 0 } ?: error("Missing Discover count")
        val records = (root["value"] as? List<*>)?.map { it as? Map<String, Any?> ?: error("Invalid Discover record") }
            ?: error("Missing Discover records")
        return DiscoverPage(count, records)
    }
    fun organization(r: Map<String, Any?>): CampusOrganization? {
        if (r.text("Status") != "Active" || r.text("Visibility") != "Public" || "University Park Orgs" !in r.strings("CategoryNames")) return null
        val id = r.id("Id") ?: return null
        val name = r.text("Name").takeIf { it.isNotBlank() } ?: return null
        return CampusOrganization(id, name, DiscoverSource.plain(r.text("Summary")), DiscoverSource.plain(r.text("Description")),
            r.strings("CategoryNames").filterNot { it == "University Park Orgs" }.sorted(),
            r.text("WebsiteKey").takeIf { it.isNotBlank() }?.let { key ->
                okhttp3.HttpUrl.Builder().scheme("https").host("discover.psu.edu").addPathSegment("organization").addPathSegment(key).build().toString()
            }, DiscoverSource.image(r.text("ProfilePicture")))
    }
    fun event(r: Map<String, Any?>): CampusEvent? {
        if (r.text("visibility") != "Public" || r.text("status") !in listOf("Approved", "Cancelled")) return null
        val id = r.id("id") ?: return null
        val start = instant(r.text("startsOn")) ?: return null
        val end = instant(r.text("endsOn"))
        if (end != null && end < start) return null
        val title = r.text("name").takeIf { it.isNotBlank() } ?: return null
        return CampusEvent(id, title, start, end, DiscoverSource.plain(r.text("description")),
            location = r.text("location"), hostNames = (r.strings("organizationNames") + r.text("organizationName").takeIf { it.isNotBlank() }.let { listOfNotNull(it) }).distinct(),
            organizationIds = (r.ids("organizationIds") + listOfNotNull(r.id("organizationId"))).distinct(),
            categories = r.strings("categoryNames"), benefits = r.strings("benefitNames"),
            officialUrl = "https://discover.psu.edu/event/$id", imageUrl = DiscoverSource.image(r.text("imagePath"), true),
            organizationImageUrl = DiscoverSource.image(r.text("organizationProfilePicture")),
            latitude = r["latitude"]?.toString()?.toDoubleOrNull(), longitude = r["longitude"]?.toString()?.toDoubleOrNull(),
            cancelled = r.text("status") == "Cancelled", onlineUrl = DiscoverSource.online(r.text("description")))
    }
    private fun instant(value: String) = runCatching { OffsetDateTime.parse(value).toInstant().toEpochMilli() }.getOrNull()
}
internal fun Map<String, Any?>.text(key: String) = DiscoverSource.cleanText(this[key] as? String ?: "")
internal fun Map<String, Any?>.strings(key: String) = (this[key] as? List<*>)?.filterIsInstance<String>()?.map(DiscoverSource::cleanText).orEmpty()
private fun identifier(value: Any?): String? = when (value) { is String -> value.takeIf { it.isNotBlank() }; is Number -> value.toLong().toString(); else -> null }
internal fun Map<String, Any?>.id(key: String) = identifier(this[key])
private fun Map<String, Any?>.ids(key: String) = (this[key] as? List<*>)?.mapNotNull(::identifier).orEmpty()

/** Occurrence-based feed parser. RRULE is deliberately not expanded. */
internal object DiscoverCalendar {
    private data class Property(val name: String, val parameters: Map<String, String>, val value: String)
    fun unescape(value: String): String = buildString {
        var escaped = false
        value.forEach { ch ->
            if (escaped) { append(if (ch == 'n' || ch == 'N') '\n' else ch); escaped = false }
            else if (ch == '\\') escaped = true else append(ch)
        }
        if (escaped) append('\\')
    }
    private fun values(value: String): List<String> {
        val parts = mutableListOf<String>(); val current = StringBuilder(); var escaped = false
        value.forEach { ch ->
            if (ch == ',' && !escaped) { parts += unescape(current.toString()); current.clear() } else current.append(ch)
            escaped = ch == '\\' && !escaped
        }
        parts += unescape(current.toString()); return parts.filter { it.isNotEmpty() }
    }
    fun parse(text: String): List<CampusEvent> {
        require(text.contains("BEGIN:VCALENDAR") && text.contains("END:VCALENDAR")) { "Unreadable event calendar" }
        val lines = mutableListOf<String>()
        text.replace("\r\n", "\n").split('\n').forEach { line ->
            if ((line.startsWith(' ') || line.startsWith('\t')) && lines.isNotEmpty()) lines[lines.lastIndex] += line.drop(1) else lines += line
        }
        var properties: MutableList<Property>? = null; var sawEvent = false
        val events = linkedMapOf<String, CampusEvent>()
        lines.forEach { line ->
            when (line) {
                "BEGIN:VEVENT" -> { require(properties == null); sawEvent = true; properties = mutableListOf() }
                "END:VEVENT" -> { properties?.let { event(it)?.let { e -> events[e.id] = e } }; properties = null }
                else -> if (properties != null && ':' in line) {
                    val key = line.substringBefore(':').split(';')
                    val params = key.drop(1).mapNotNull { p -> if ('=' in p) p.substringBefore('=').uppercase() to p.substringAfter('=').trim('"') else null }.toMap()
                    properties.add(Property(key.first().uppercase(), params, line.substringAfter(':')))
                }
            }
        }
        require(properties == null && (!sawEvent || events.isNotEmpty())) { "Incomplete event calendar" }
        return events.values.toList()
    }
    private fun date(p: Property): Long? = runCatching {
        val zone = if (p.value.endsWith('Z')) ZoneOffset.UTC else runCatching { ZoneId.of(p.parameters["TZID"].orEmpty()) }.getOrDefault(DiscoverSource.zone)
        if (p.parameters["VALUE"] == "DATE" || p.value.length == 8)
            LocalDate.parse(p.value, DateTimeFormatter.BASIC_ISO_DATE).atStartOfDay(zone).toInstant().toEpochMilli()
        else LocalDateTime.parse(p.value.removeSuffix("Z"), DateTimeFormatter.ofPattern("uuuuMMdd'T'HHmmss").withResolverStyle(ResolverStyle.STRICT)).atZone(zone).toInstant().toEpochMilli()
    }.getOrNull()
    private fun event(p: List<Property>): CampusEvent? {
        fun property(name: String) = p.firstOrNull { it.name == name }
        fun text(name: String) = property(name)?.let { unescape(it.value) }.orEmpty()
        val startP = property("DTSTART") ?: return null
        val start = date(startP) ?: return null
        val end = property("DTEND")?.let(::date)
        if (end != null && end < start || text("UID").isBlank() || text("SUMMARY").isBlank()) return null
        val url = DiscoverSource.https(text("URL")) ?: DiscoverSource.https(text("UID"))
        var hosts = p.filter { it.name == "X-HOSTS" }.flatMap { values(it.value) }
        if (hosts.isEmpty()) property("ORGANIZER")?.let { organizer ->
            val name = organizer.parameters["CN"] ?: organizer.value
            if (!name.startsWith("mailto:")) hosts = listOf(unescape(name))
        }
        val lines = text("DESCRIPTION").lines()
        if (hosts.isEmpty()) hosts = lines.firstOrNull { it.startsWith("Hosted by: ") }?.removePrefix("Hosted by: ")?.let(::listOf).orEmpty()
        val online = lines.firstOrNull { it.startsWith("Online Location: ") }?.removePrefix("Online Location: ")?.trim()?.let(DiscoverSource::https)
        val prose = lines.filterNot { it.startsWith("Hosted by: ") || it.startsWith("Online Location: ") || it.startsWith("Additional Information can be found at: ") }.joinToString("\n").trim()
        val geo = text("GEO").split(';').mapNotNull(String::toDoubleOrNull)
        return CampusEvent(DiscoverSource.eventId(url, text("UID")), text("SUMMARY"), start, end, prose,
            allDay = startP.parameters["VALUE"] == "DATE" || startP.value.length == 8,
            location = text("LOCATION"), hostNames = hosts, categories = p.filter { it.name == "CATEGORIES" }.flatMap { values(it.value) },
            officialUrl = url, latitude = geo.takeIf { it.size == 2 }?.get(0), longitude = geo.takeIf { it.size == 2 }?.get(1),
            source = EventSource.CALENDAR, cancelled = text("STATUS") == "CANCELLED", onlineUrl = online)
    }
}
