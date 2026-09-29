package com.ryannair05.meetandeat.dining

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import java.io.IOException
import java.net.HttpURLConnection
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

sealed class DiningSourceException(message: String, cause: Throwable? = null) : IOException(message, cause) {
    class Network(cause: Throwable) : DiningSourceException("The dining service could not be reached.", cause)
    class Http(val status: Int) : DiningSourceException("The dining service returned HTTP $status.")
    class Markup(message: String) : DiningSourceException(message)
    data object NoPublishedMenu : DiningSourceException("No menu was published for this date.")
}

internal data class MealOption(val value: String, val name: String, val order: Int)

class PennStateDiningSource(
    private val endpoint: String = MENU_URL,
    private val clock: () -> Long = System::currentTimeMillis,
    private val transport: (suspend (String, String, String?) -> String)? = null,
) {
    private val requestBudget = Semaphore(3)
    // Penn State resolves a nutrition `mid` through the ColdFusion session established by a
    // menu request. HttpURLConnection does not retain those cookies unless we do it explicitly.
    private val cookies = CookieManager(null, CookiePolicy.ACCEPT_ALL)

    internal fun hasSessionFor(url: String?): Boolean {
        val uri = url?.let { runCatching { URI(it) }.getOrNull() } ?: return false
        return synchronized(cookies) { cookies.cookieStore.get(uri).isNotEmpty() }
    }

    suspend fun loadMenu(
        hall: PSUDiningHall,
        date: LocalDate,
        preferredMealId: String? = null,
        onPartial: suspend (MenuDaySnapshot) -> Unit = {},
        preferredMeal: (List<DiningMealPeriod>) -> String? = { preferredMealId },
    ): MenuDaySnapshot = withContext(Dispatchers.Default) {
        val baseFields = linkedMapOf(
            "selMenuDate" to date.format(SOURCE_DATE),
            "selCampus" to hall.menuNumber.toString(),
        )
        val discoveryHtml = post(baseFields)
        val discovery = Jsoup.parse(discoveryHtml, endpoint)
        val options = mealOptions(discovery)
        if (options.isEmpty()) {
            if (explicitlyUnavailable(discovery)) {
                return@withContext snapshot(hall, date, emptyList())
            }
            throw DiningSourceException.Markup("Penn State's meal selector was missing.")
        }

        // Discovery contains the server-selected meal, never the caller's requested meal.
        val selectedValue = discovery.selectFirst("#selMeal option[selected]")?.attr("value")
        val discoveredOption = options.firstOrNull { it.value == selectedValue } ?: options.first()
        val choices = options.map { DiningMealPeriod(periodId(it.name, it.value), it.name, it.order, emptyList()) }
        val preferredId = preferredMeal(choices)
        val preferred = options.firstOrNull { periodId(it.name, it.value) == preferredId } ?: discoveredOption
        val loaded = mutableMapOf<String, DiningMealPeriod>()
        val progressMutex = Mutex()
        suspend fun publish(period: DiningMealPeriod? = null) = progressMutex.withLock {
            if (period != null) loaded[period.id] = period
            val pending = choices.map { it.id }.toSet() - loaded.keys
            onPartial(snapshot(hall, date, choices.map { loaded[it.id] ?: it }).copy(pendingMealIds = pending))
        }
        // Publish the picker immediately, but never substitute another meal's items for the selection.
        publish()
        val discovered = runCatching { parsePeriod(discovery, discoveredOption) }
        discovered.getOrNull()?.let { publish(it) }
        val pending = options.filter { it != discoveredOption }
            .sortedBy { if (it == preferred) -1 else it.order }
        val outcomes = supervisorScope {
            pending.map { option ->
                async {
                    try {
                        val html = post(baseFields + ("selMeal" to option.value))
                        val period = parsePeriod(Jsoup.parse(html, endpoint), option)
                        publish(period)
                        Result.success(period)
                    } catch (error: CancellationException) { throw error }
                    catch (error: Exception) { Result.failure<DiningMealPeriod>(error) }
                }
            }.awaitAll()
        }
        // A failed sibling must not cancel usable meals or poison the complete-day cache.
        discovered.exceptionOrNull()?.let { throw it }
        outcomes.firstNotNullOfOrNull { it.exceptionOrNull() }?.let { throw it }
        snapshot(hall, date, loaded.values.sortedBy { it.sourceOrder })
    }

    suspend fun loadItemDetail(item: DiningMenuItem): MenuItemDetail {
        val url = item.detailUrl ?: throw DiningSourceException.Markup("This item has no detail page.")
        val document = Jsoup.parse(get(url), url)
        val pageText = document.text().lowercase(Locale.US)
        if (pageText.contains("nutrition information is not available for the selected item")) {
            throw DiningSourceException.NoPublishedMenu
        }
        val ingredients = document.selectFirst(".content-card--ingredients p")?.text()?.takeIf(String::isNotBlank)
        val allergens = document.selectFirst(".content-card[aria-labelledby=allergensHeading] p")?.text()?.takeIf(String::isNotBlank)
        val nutrition = buildList {
            document.select(".nutrition-summary .summary-value").forEach { summary ->
                val name = summary.selectFirst("strong")?.text()?.trim(':', ' ') ?: return@forEach
                val value = summary.ownText().trim()
                if (value.isNotBlank()) add(NutritionFact(name, value))
            }
            document.select(".nutrition-facts-card .fact-row").forEach { row ->
                val name = row.selectFirst(".fact-name")?.text() ?: return@forEach
                val amount = row.selectFirst(".fact-amount")?.text() ?: return@forEach
                val dailyValue = row.selectFirst(".fact-dv")?.text()?.takeUnless { it == "-" || it == "—" }
                add(NutritionFact(name, dailyValue?.let { "$amount · $it" } ?: amount))
            }
        }
        if (ingredients == null && allergens == null && nutrition.isEmpty()) {
            throw DiningSourceException.Markup("Penn State did not publish item details.")
        }
        return MenuItemDetail(item.id, url, clock(), ingredients, allergens, nutrition)
    }

    internal fun mealOptions(document: Document): List<MealOption> {
        val selector = document.selectFirst("#selMeal") ?: return emptyList()
        return selector.select("option").mapNotNull { option ->
            val name = option.text().trim()
            if (name.isBlank() || name.equals("Select Meal", true)) null
            else MealOption(option.attr("value").trim(), name, 0)
        }.mapIndexed { index, option -> option.copy(order = index) }
    }

    internal fun parsePeriod(document: Document, option: MealOption): DiningMealPeriod {
        val periodId = periodId(option.name, option.value)
        val usedSectionIds = mutableMapOf<String, Int>()
        val sections = document.select(".menu-category-section").mapIndexedNotNull { sectionOrder, sourceSection ->
            val name = sourceSection.selectFirst(".nutrition-category-title")?.text()?.trim()
                ?.takeIf(String::isNotBlank) ?: return@mapIndexedNotNull null
            val seen = mutableSetOf<String>()
            val items = sourceSection.select(".daily-menu-item").mapIndexedNotNull { _, sourceItem ->
                val link = sourceItem.selectFirst("a.daily-menu-item__link") ?: return@mapIndexedNotNull null
                val itemName = link.text().trim().takeIf(String::isNotBlank) ?: return@mapIndexedNotNull null
                val resolved = link.absUrl("href").takeIf(String::isNotBlank)
                val labels = sourceItem.select(".daily-menu-item__icons img[alt]")
                    .map { it.attr("alt").trim() }.filter(String::isNotBlank).distinct()
                val id = resolved?.let(::menuItemId) ?: "name:${normalizeDiningText(itemName, "-")}" 
                val occurrence = listOf(id, itemName, resolved.orEmpty(), labels.joinToString("|")).joinToString("::")
                if (!seen.add(occurrence)) return@mapIndexedNotNull null
                DiningMenuItem(id, itemName, resolved, seen.size - 1, labels)
            }
            if (items.isEmpty()) return@mapIndexedNotNull null
            val baseId = "$periodId-section-${normalizeDiningText(name, "-")}" 
            val count = (usedSectionIds[baseId] ?: 0) + 1
            usedSectionIds[baseId] = count
            DiningMenuSection(if (count == 1) baseId else "$baseId-$count", name, sectionOrder, items)
        }
        if (sections.isEmpty() && !explicitlyUnavailable(document)) {
            throw DiningSourceException.Markup("Penn State's menu sections could not be read.")
        }
        return DiningMealPeriod(periodId, option.name, option.order, sections)
    }

    private fun snapshot(hall: PSUDiningHall, date: LocalDate, meals: List<DiningMealPeriod>) =
        MenuDaySnapshot(hallId = hall.id, date = date.toString(), fetchedAtEpochMillis = clock(), meals = meals)

    private fun explicitlyUnavailable(document: Document): Boolean {
        val text = document.text().lowercase(Locale.US)
        return listOf("no menu", "menu is not available", "no items found", "no menu items").any(text::contains)
    }

    private suspend fun post(fields: Map<String, String>): String = requestBudget.withPermit {
        request(endpoint, "POST", fields.entries.joinToString("&") {
            "${encode(it.key)}=${encode(it.value)}"
        })
    }

    private suspend fun get(url: String): String = requestBudget.withPermit { request(url, "GET", null) }

    private suspend fun request(url: String, method: String, body: String?): String = withContext(Dispatchers.IO) {
        try {
            coroutineContext.ensureActive()
            transport?.let { return@withContext it(url, method, body) }
            val uri = URI(url)
            val connection = uri.toURL().openConnection() as HttpURLConnection
            try {
                connection.requestMethod = method
                connection.connectTimeout = 15_000
                connection.readTimeout = 20_000
                connection.setRequestProperty("User-Agent", "MeetAndEat-Android/1.0")
                synchronized(cookies) { cookies.get(uri, emptyMap()) }
                    .forEach { (name, values) ->
                        values.forEach { value -> connection.addRequestProperty(name, value) }
                    }
                if (body != null) {
                    connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
                    connection.outputStream.use { it.write(body.toByteArray()) }
                }
                val responseCode = connection.responseCode
                val responseHeaders = connection.headerFields.entries.mapNotNull { (name, values) ->
                    name?.let { it to values }
                }.toMap()
                synchronized(cookies) { cookies.put(uri, responseHeaders) }
                if (responseCode !in 200..299) throw DiningSourceException.Http(responseCode)
                if (connection.contentLengthLong > MAX_RESPONSE_BYTES) {
                    throw DiningSourceException.Markup("The dining response was too large.")
                }
                connection.inputStream.use { stream ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        coroutineContext.ensureActive()
                        val count = stream.read(buffer)
                        if (count < 0) break
                        if (output.size() + count > MAX_RESPONSE_BYTES) throw DiningSourceException.Markup("The dining response was too large.")
                        output.write(buffer, 0, count)
                    }
                    val bytes = output.toByteArray()
                    coroutineContext.ensureActive()
                    if (bytes.size > MAX_RESPONSE_BYTES) throw DiningSourceException.Markup("The dining response was too large.")
                    bytes.toString(Charsets.UTF_8)
                }
                    .takeIf(String::isNotBlank) ?: throw DiningSourceException.Markup("The dining service returned an empty page.")
            } finally {
                connection.disconnect()
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: DiningSourceException) {
            throw error
        } catch (error: Throwable) {
            throw DiningSourceException.Network(error)
        }
    }

    companion object {
        private const val MAX_RESPONSE_BYTES = 5 * 1024 * 1024
        const val MENU_URL = "https://www.absecom.psu.edu/menus/user-pages/daily-menu.cfm"
        private val SOURCE_DATE = DateTimeFormatter.ofPattern("M/d/yyyy", Locale.US)
        private fun encode(value: String) = URLEncoder.encode(value, StandardCharsets.UTF_8.name())
        private fun periodId(name: String, value: String): String {
            val semantic = normalizeDiningText(name, "-")
            val source = normalizeDiningText(value, "-")
            return if (source.isBlank() || source == semantic) "period-$semantic" else "period-$source-$semantic"
        }
        private fun menuItemId(url: String): String {
            val query = runCatching { URI(url).rawQuery }.getOrNull().orEmpty()
            val mid = query.split('&').firstOrNull { it.startsWith("mid=") }?.substringAfter("mid=")
            if (!mid.isNullOrBlank()) return "mid:$mid"
            return "url:" + MessageDigest.getInstance("SHA-256")
                .digest(url.toByteArray()).take(8).joinToString("") { "%02x".format(it) }
        }
    }
}
