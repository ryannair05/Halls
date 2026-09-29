package com.ryannair05.meetandeat.discover

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.CalendarContract
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

internal data class CalendarDraft(val title: String, val start: Long, val end: Long, val allDay: Boolean, val location: String, val notes: String)
internal fun calendarDraft(event: CampusEvent): CalendarDraft {
    val end = event.end ?: event.startTime.let { if (event.allDay) it.plusDays(1) else it.plusHours(1) }.toInstant().toEpochMilli()
    fun allDayMillis(value: Long) = Instant.ofEpochMilli(value).atZone(DiscoverSource.zone).toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    return CalendarDraft(event.title, if (event.allDay) allDayMillis(event.start) else event.start,
        if (event.allDay) allDayMillis(end) else end, event.allDay, event.location,
        listOfNotNull(event.description.takeIf { it.isNotBlank() }, event.officialUrl).joinToString("\n\n"))
}
internal fun directionsUrl(event: CampusEvent): String {
    val lat = event.latitude; val lon = event.longitude
    val destination = if (lat != null && lon != null && lat in -90.0..90.0 && lon in -180.0..180.0) "$lat,$lon" else "${event.location}, University Park, PA"
    return okhttp3.HttpUrl.Builder().scheme("https").host("www.google.com").addPathSegments("maps/dir/")
        .addQueryParameter("api", "1").addQueryParameter("destination", destination).addQueryParameter("travelmode", "walking").build().toString()
}
internal fun eventTime(event: CampusEvent): String {
    val date = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
    val time = DateTimeFormatter.ofPattern("h:mm a")
    val start = event.startTime
    val end = event.end?.let { Instant.ofEpochMilli(if (event.allDay) it - 1 else it).atZone(DiscoverSource.zone) }
    return when {
        event.allDay -> start.format(date) + (if (end != null && end.toLocalDate() != start.toLocalDate()) " – ${end.format(date)}" else "") + " · All day"
        end == null -> "${start.format(date)} · ${start.format(time)} ET"
        start.toLocalDate() == end.toLocalDate() -> "${start.format(date)} · ${start.format(time)}–${end.format(time)} ET"
        else -> "${start.format(date)}, ${start.format(time)} – ${end.format(date)}, ${end.format(time)} ET"
    }
}
internal class DiscoverActions(private val context: Context, private val error: (String) -> Unit) {
    fun open(url: String?) {
        val valid = DiscoverSource.https(url) ?: return
        try { CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, valid.toUri()) }
        catch (_: ActivityNotFoundException) { launch(Intent(Intent.ACTION_VIEW, valid.toUri()), "No browser is available to open this page.") }
    }
    fun share(url: String?) {
        val valid = DiscoverSource.https(url) ?: return
        launch(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, valid), "Share"), "No sharing app is available.")
    }
    fun directions(event: CampusEvent) = launch(Intent(Intent.ACTION_VIEW, directionsUrl(event).toUri()), "No maps or browser app is available.")
    fun calendar(event: CampusEvent) {
        if (event.cancelled) return
        val draft = calendarDraft(event)
        launch(Intent(Intent.ACTION_INSERT, CalendarContract.Events.CONTENT_URI)
            .putExtra(CalendarContract.Events.TITLE, draft.title)
            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, draft.start)
            .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, draft.end)
            .putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, draft.allDay)
            .putExtra(CalendarContract.Events.EVENT_TIMEZONE, if (draft.allDay) "UTC" else DiscoverSource.zone.id)
            .putExtra(CalendarContract.Events.EVENT_LOCATION, draft.location)
            .putExtra(CalendarContract.Events.DESCRIPTION, draft.notes), "No calendar app is available. You can still save this event in Discover.")
    }
    private fun launch(intent: Intent, message: String) {
        try { context.startActivity(intent) } catch (_: ActivityNotFoundException) { error(message) } catch (_: SecurityException) { error(message) }
    }
}

/** List metadata omits the repeated year; details retain the complete campus-local interval. */
internal fun eventRowTime(event: CampusEvent): String {
    val start = event.startTime
    val day = DateTimeFormatter.ofPattern("MMM d")
    val time = DateTimeFormatter.ofPattern("h:mm a")
    val end = event.end?.let { Instant.ofEpochMilli(if (event.allDay) it - 1 else it).atZone(DiscoverSource.zone) }
    val dates = start.format(day) + if (end != null && start.toLocalDate() != end.toLocalDate()) "–${end.format(day)}" else ""
    if (event.allDay) return "$dates · All day"
    return "$dates · ${start.format(time)}" + if (end != null && start.toLocalDate() == end.toLocalDate()) "–${end.format(time)}" else ""
}
