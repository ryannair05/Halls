package com.ryannair05.meetandeat.journal

import android.content.Context
import android.util.AtomicFile
import com.ryannair05.meetandeat.dining.*
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.time.LocalDate
import java.util.Locale
import java.util.UUID

data class JournalItem(val item: DiningMenuItem, val servings: Double = 1.0, val detail: MenuItemDetail? = null)
data class JournalMeal(
    val id: String = UUID.randomUUID().toString(),
    val hallId: String,
    val date: String,
    val meal: String,
    val eaten: Boolean = false,
    val items: List<JournalItem>,
)
data class JournalFile(val version: Int = 1, val meals: List<JournalMeal> = emptyList())

enum class JournalNutrient(val label: String, val unit: String, val keys: Set<String>) {
    CALORIES("Calories", "kcal", setOf("calories", "energy")),
    PROTEIN("Protein", "g", setOf("protein")),
    CARBS("Carbs", "g", setOf("total carbohydrate", "total carbohydrates", "carbohydrate")),
    FAT("Fat", "g", setOf("total fat", "fat"));

    fun amount(item: JournalItem): Double? {
        val fact = item.detail?.nutrition?.firstOrNull { normalizeDiningText(it.name) in keys } ?: return null
        val match = NUMBER.matchEntire(fact.value.substringBefore('·').trim()) ?: return null
        val value = match.groupValues[1].toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 } ?: return null
        val unit = match.groupValues[2].lowercase(Locale.US)
        val scale = if (this == CALORIES) {
            if (unit !in setOf("", "kcal", "cal", "calories")) return null
            1.0
        } else when (unit) { "g" -> 1.0; "mg" -> 0.001; "mcg", "µg" -> 0.000001; else -> return null }
        return value * scale * item.servings
    }
    companion object { private val NUMBER = Regex("([0-9]+(?:\\.[0-9]+)?)\\s*(kcal|calories|cal|mg|mcg|µg|g)?", RegexOption.IGNORE_CASE) }
}

fun nutritionSummary(items: List<JournalItem>): String = JournalNutrient.entries.joinToString(" · ") { nutrient ->
    val values = items.mapNotNull(nutrient::amount)
    val value = if (values.isEmpty()) "—" else String.format(Locale.US, "%.0f", values.sum())
    "${nutrient.label} $value${if (values.isNotEmpty()) " ${nutrient.unit}" else ""}${if (values.isNotEmpty() && values.size < items.size) " (partial)" else ""}"
}

/** App-private durable storage, independent of the expendable menu cache. */
class MealJournal private constructor(context: Context) {
    private val file = AtomicFile(File(context.filesDir, "my-meals-v1.json"))
    private val adapter = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build().adapter(JournalFile::class.java)
    private val mutex = Mutex()
    private var loaded = false
    private val mutableMeals = MutableStateFlow<List<JournalMeal>>(emptyList())
    val meals = mutableMeals.asStateFlow()

    private fun read() {
        if (loaded) return
        val saved = try { file.openRead().bufferedReader().use { requireNotNull(adapter.fromJson(it.readText())) { "Your saved journal could not be read." } } }
        catch (error: java.io.FileNotFoundException) { null }
        if (saved != null) {
            require(saved.version == 1) { "This journal needs a newer version of Halls." }
            mutableMeals.value = saved.meals
        }
        loaded = true
    }
    suspend fun load() = withContext(Dispatchers.IO) { mutex.withLock { read() } }
    private suspend fun change(transform: (List<JournalMeal>) -> List<JournalMeal>) = withContext(Dispatchers.IO) {
        mutex.withLock {
            read()
            val next = transform(mutableMeals.value).sortedByDescending { it.date }
            val bytes = adapter.toJson(JournalFile(meals = next)).toByteArray(Charsets.UTF_8)
            val output = file.startWrite()
            try { output.write(bytes); file.finishWrite(output) }
            catch (error: Throwable) { file.failWrite(output); throw error }
            mutableMeals.value = next
        }
    }
    suspend fun save(meal: JournalMeal) {
        require(meal.items.isNotEmpty() && meal.items.all { it.servings.isFinite() && it.servings in 0.25..20.0 })
        require(!meal.eaten || !LocalDate.parse(meal.date).isAfter(LocalDate.now(PennStateZone))) { "Eaten meals cannot be in the future." }
        change { rows -> rows.filterNot { it.id == meal.id } + meal }
    }
    suspend fun delete(id: String) = change { rows -> rows.filterNot { it.id == id } }

    fun csv(): String {
        fun cell(value: String) = "\"${value.replace("\"", "\"\"").let { if (it.firstOrNull() in listOf('=', '+', '-', '@', '\t', '\r')) "'$it" else it }}\""
        return buildString {
            append("Date,Status,Hall,Meal,Item,Servings,Calories,Protein (g),Carbs (g),Fat (g)\r\n")
            meals.value.forEach { meal -> meal.items.forEach { item ->
                val values = listOf(meal.date, if (meal.eaten) "Eaten" else "Planned", meal.hallId, meal.meal, item.item.name, item.servings.toString()) + JournalNutrient.entries.map { it.amount(item)?.toString().orEmpty() }
                append(values.joinToString(",", transform = ::cell)); append("\r\n")
            } }
        }
    }
    companion object {
        @Volatile private var instance: MealJournal? = null
        fun get(context: Context): MealJournal = instance ?: synchronized(this) {
            instance ?: MealJournal(context.applicationContext).also { instance = it }
        }
    }
}

/** Transient confirmations are rendered by the root Material snackbar host. */
object MealFeedback {
    val messages = kotlinx.coroutines.flow.MutableSharedFlow<String>(extraBufferCapacity = 4)
}
