package com.ryannair05.meetandeat.discover

import androidx.annotation.Keep
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.AtomicMoveNotSupportedException
import java.time.Instant
import java.util.concurrent.TimeUnit

internal data class DiscoverResponse(val body: String, val contentType: String)
internal fun interface DiscoverHttp {
    suspend fun get(path: String, query: Map<String, String>): DiscoverResponse
}
internal class PublicDiscoverHttp : DiscoverHttp {
    private val client = OkHttpClient.Builder().connectTimeout(25, TimeUnit.SECONDS)
        .readTimeout(25, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS).build()
    override suspend fun get(path: String, query: Map<String, String>) = withContext(Dispatchers.IO) {
        val url = okhttp3.HttpUrl.Builder().scheme("https").host("discover.psu.edu").encodedPath(path)
            .apply { query.forEach { (key, value) -> addQueryParameter(key, value) } }.build()
        client.newCall(Request.Builder().url(url).build()).execute().use { response ->
            check(response.isSuccessful) { "Discover is temporarily unavailable (${response.code})." }
            val body = response.body ?: error("Discover returned an empty response.")
            DiscoverResponse(body.string(), body.contentType()?.toString().orEmpty())
        }
    }
}
@Keep internal data class DiscoverCache(
    val version: Int = 1, val snapshot: DiscoverSnapshot = DiscoverSnapshot(),
    val jsonAvailable: Boolean? = null, val jsonChecked: Long? = null,
    val pagingAvailable: Boolean? = null, val pagingChecked: Long? = null,
)
internal interface DiscoverStore {
    fun cache(): DiscoverCache
    fun writeCache(value: DiscoverCache)
    fun saved(): DiscoverSaved
    fun writeSaved(value: DiscoverSaved)
}
internal class DiscoverFileStore(private val directory: File) : DiscoverStore {
    private val moshi = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build()
    private fun <T> read(name: String, type: Class<T>): T? {
        val file = File(directory, name)
        if (!file.exists()) return null
        return requireNotNull(moshi.adapter(type).fromJson(file.readText())) { "Unreadable saved data" }
    }
    private fun <T> write(name: String, value: T, type: Class<T>) {
        check(directory.isDirectory || directory.mkdirs()) { "Cannot open Discover storage" }
        val temp = File.createTempFile(name, ".tmp", directory)
        try {
            temp.outputStream().use { output ->
                output.write(moshi.adapter(type).toJson(value).toByteArray(Charsets.UTF_8)); output.fd.sync()
            }
            try { Files.move(temp.toPath(), File(directory, name).toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            catch (_: AtomicMoveNotSupportedException) { Files.move(temp.toPath(), File(directory, name).toPath(), StandardCopyOption.REPLACE_EXISTING) }
        } finally { temp.delete() }
    }
    override fun cache() = runCatching { read("cache-v1.json", DiscoverCache::class.java)?.takeIf { it.version == 1 } }.getOrNull() ?: DiscoverCache()
    override fun writeCache(value: DiscoverCache) = write("cache-v1.json", value, DiscoverCache::class.java)
    override fun saved(): DiscoverSaved = (read("saved-v1.json", DiscoverSaved::class.java) ?: DiscoverSaved()).also { require(it.version == 1) { "Saved items require a newer app" } }
    override fun writeSaved(value: DiscoverSaved) = write("saved-v1.json", value, DiscoverSaved::class.java)
}
internal data class DiscoverRefresh(val snapshot: DiscoverSnapshot, val issues: List<String> = emptyList())
internal fun stale(timestamp: Long?, age: Long, now: Long) = timestamp == null || timestamp > now || now - timestamp >= age
internal class DiscoverRepository(private val store: DiscoverStore, private val http: DiscoverHttp = PublicDiscoverHttp()) {
    private val refreshMutex = Mutex()
    private val saveMutex = Mutex()
    private var cache: DiscoverCache? = null
    @Volatile private var generation = 0L
    private var lastRefresh = DiscoverRefresh(DiscoverSnapshot())
    suspend fun cached(): DiscoverSnapshot = withContext(Dispatchers.IO) { refreshMutex.withLock { load().snapshot } }
    private fun load(): DiscoverCache = cache ?: store.cache().also { cache = it }
    suspend fun saved(): DiscoverSaved = withContext(Dispatchers.IO) { saveMutex.withLock { store.saved() } }
    suspend fun save(value: DiscoverSaved) = withContext(Dispatchers.IO) { saveMutex.withLock { store.writeSaved(value) } }
    suspend fun refresh(force: Boolean = false, now: Long = System.currentTimeMillis()): DiscoverRefresh {
        val startedGeneration = generation
        return withContext(Dispatchers.IO) {
            refreshMutex.withLock {
                if (startedGeneration != generation) return@withLock lastRefresh
                var current = load()
                var snapshot = current.snapshot
                val issues = mutableListOf<String>()
                coroutineScope {
                    val refreshOrganizations = force || stale(snapshot.organizationsUpdated, 12 * 3_600_000L, now)
                    // Campus classification depends on the directory. Re-fetch events when
                    // refreshing it so an earlier missing directory cannot hide fresh events.
                    val events = if (refreshOrganizations || stale(snapshot.eventsUpdated, 15 * 60_000L, now)) async { attempt { events(current, now) } } else null
                    if (refreshOrganizations) {
                        attempt { organizations(current, now) }.fold(onSuccess = { result ->
                            current = current.copy(pagingAvailable = result.paging, pagingChecked = result.checked)
                            if (result.complete || !snapshot.directoryComplete) snapshot = snapshot.copy(
                                organizations = result.items, directoryComplete = result.complete, organizationsUpdated = now)
                            if (!result.complete) issues += "Limited club directory. Some clubs and their events may be missing."
                        }, onFailure = { issues += "Clubs: ${it.message ?: "Could not update."}" })
                    }
                    events?.await()?.fold(onSuccess = { result ->
                        current = current.copy(jsonAvailable = result.json, jsonChecked = result.checked)
                        snapshot = snapshot.copy(events = classifyCampus(result.items, snapshot.organizations)
                            .sortedWith(compareBy<CampusEvent> { it.start }.thenBy { it.id }), eventsUpdated = now, eventSource = result.source)
                    }, onFailure = { issues += "Events: ${it.message ?: "Could not update."}" })
                }
                current = current.copy(snapshot = snapshot); cache = current
                attempt { store.writeCache(current) }.onFailure { issues += "Offline cache could not be updated." }
                lastRefresh = DiscoverRefresh(snapshot, issues); generation++
                lastRefresh
            }
        }
    }
    private suspend fun page(path: String, query: Map<String, String> = emptyMap()): DiscoverPage {
        val response = http.get(path, query)
        check(response.contentType.contains("json", ignoreCase = true)) { "Discover returned an unreadable response." }
        return DiscoverJson.page(response.body)
    }
    private suspend fun organizationPage(top: Int? = null, skip: Int = 0) = page("/api/discovery/search/organizations",
        if (top == null) emptyMap() else mapOf("top" to "$top", "skip" to "$skip", "orderBy[0]" to "UpperName asc"))
    private data class Organizations(val items: List<CampusOrganization>, val complete: Boolean, val paging: Boolean?, val checked: Long?)
    private suspend fun organizations(cache: DiscoverCache, now: Long): Organizations {
        val bare = organizationPage()
        var paging = cache.pagingAvailable; var checked = cache.pagingChecked
        if (bare.records.size < bare.count && stale(checked, 24 * 3_600_000L, now)) {
            paging = attempt { coroutineScope {
                val a = async { organizationPage(1) }; val b = async { organizationPage(1, 1) }
                val first = a.await(); val second = b.await()
                first.records.size == 1 && second.records.size == 1 && first.records[0].id("Id") != second.records[0].id("Id")
            } }.getOrDefault(false)
            checked = now
        }
        var records = bare.records
        var complete = records.mapNotNull { it.id("Id") }.distinct().size >= bare.count
        if (!complete && paging == true) {
            attempt { allPages(organizationPage(100), "Id") { organizationPage(100, it) } }.onSuccess {
                records = it; complete = it.size >= bare.count
            }
        }
        return Organizations(records.mapNotNull(DiscoverJson::organization).distinctBy { it.id }.sortedBy { DiscoverSource.normalized(it.name) }, complete, paging, checked)
    }
    private data class Events(val items: List<CampusEvent>, val source: EventSource, val json: Boolean?, val checked: Long?)
    private suspend fun events(cache: DiscoverCache, now: Long): Events {
        var checked = cache.jsonChecked; var available = cache.jsonAvailable
        if (available != false || stale(checked, 24 * 3_600_000L, now)) {
            val result = attempt {
                suspend fun request(skip: Int) = page("/api/discovery/event/search", mapOf("take" to "100", "skip" to "$skip", "status" to "Approved",
                    "endsAfter" to Instant.ofEpochMilli(now).toString(), "orderByField" to "endsOn", "orderByDirection" to "ascending"))
                allPages(request(0), "id") { request(it) }.mapNotNull(DiscoverJson::event)
            }
            checked = now
            if (result.isSuccess) {
                var events = result.getOrThrow()
                if (events.any { it.online && it.onlineUrl == null }) attempt { calendar() }.onSuccess { feed ->
                    val links = feed.associateBy { it.id }
                    events = events.map { if (it.onlineUrl == null) it.copy(onlineUrl = links[it.id]?.onlineUrl) else it }
                }
                return Events(events, EventSource.JSON, true, checked)
            }
            available = false
        }
        return Events(calendar(), EventSource.CALENDAR, available, checked)
    }
    private suspend fun calendar() = DiscoverCalendar.parse(http.get("/events.ics", emptyMap()).body)
}
/** Reject incomplete/overlapping pagination and respect server page-size caps. */
internal suspend fun allPages(first: DiscoverPage, idKey: String, next: suspend (Int) -> DiscoverPage): List<Map<String, Any?>> = coroutineScope {
    require(first.records.isNotEmpty() || first.count == 0) { "Incomplete Discover response" }
    val result = first.records.toMutableList()
    val seen = result.map { requireNotNull(it.id(idKey)) { "Missing record identifier" } }.toMutableSet()
    require(seen.size == result.size) { "Discover repeated a page" }
    val size = first.records.size
    if (size > 0) {
        var offset = size
        while (offset < first.count) {
            val offsets = buildList { repeat(4) { if (offset < first.count) { add(offset); offset += size } } }
            offsets.map { skip -> async { next(skip) } }.awaitAll().forEach { page ->
                require(page.records.isNotEmpty()) { "Incomplete Discover response" }
                page.records.forEach { record -> require(seen.add(requireNotNull(record.id(idKey)))) { "Discover repeated a page" }; result += record }
            }
        }
    }
    require(result.size >= first.count) { "Incomplete Discover response" }
    result
}
internal suspend fun <T> attempt(block: suspend () -> T): Result<T> = try { Result.success(block()) }
catch (cancelled: CancellationException) { throw cancelled }
catch (error: Exception) { Result.failure(error) }
