package com.ryannair05.meetandeat.dining

import com.squareup.moshi.Moshi
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.time.LocalDate

data class DiningHoursSnapshot(
    val halls: Map<PSUDiningHall, DayHours?>,
    val stations: Map<PSUDiningHall, Map<String, DayHours>>,
)

internal fun hasSupportedHours(values: Map<String, Map<String, DayHours>>) =
    PSUDiningHall.entries.any { hall ->
        values[hall.id]?.values?.any { it.explicitlyClosed || it.intervals.isNotEmpty() } == true
    }

/** One aggregate request serves every hall and station. Network work never holds the cache lock. */
internal class PennStateHoursStore(
    private val cacheFile: File,
    private val moshi: Moshi,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val fetch: suspend () -> String = ::fetchPennStateHours,
) {
    private data class Cache(val fetchedAt: Long, val schemaVersion: Int = 2, val values: Map<String, Map<String, DayHours>>)

    private val mutex = Mutex()
    private var memory: Cache? = null
    private var loadedDisk = false
    private var retryAfter = 0L
    private var refreshTask: Deferred<Cache?>? = null
    private val adapter = moshi.adapter(Cache::class.java)

    suspend fun snapshot(date: LocalDate, cacheOnly: Boolean = false, forceRefresh: Boolean = false): DiningHoursSnapshot {
        val values = load(cacheOnly, forceRefresh)?.values.orEmpty()
        return DiningHoursSnapshot(
            PSUDiningHall.entries.associateWith { values[it.id]?.get(date.dayOfWeek.name) },
            PSUDiningHall.entries.associateWith { hall ->
                val prefix = "station:${hall.id}:"
                values.filterKeys { it.startsWith(prefix) }.mapNotNull { (key, week) ->
                    week[date.dayOfWeek.name]?.let { key.removePrefix(prefix) to it }
                }.toMap()
            },
        )
    }

    suspend fun hours(hall: PSUDiningHall, date: LocalDate, cacheOnly: Boolean = false): DayHours? =
        snapshot(date, cacheOnly).halls[hall]

    private suspend fun load(cacheOnly: Boolean, force: Boolean): Cache? = withContext(Dispatchers.IO) {
        val task = mutex.withLock {
            if (!loadedDisk) {
                loadedDisk = true
                memory = runCatching { adapter.fromJson(cacheFile.readText()) }.getOrNull()
                    ?.takeIf { it.schemaVersion == 2 && hasSupportedHours(it.values) }
            }
            val cached = memory?.takeIf(::isFresh)
            if (cacheOnly || (!force && cached != null)) return@withContext cached
            // Join a refresh even when the caller explicitly requests a retry.
            refreshTask?.let { return@withLock it }
            if (!force && nowMillis() < retryAfter) return@withContext cached
            scope.async {
                try {
                    val result = Cache(nowMillis(), values = PennStateHoursParser.parse(fetch(), moshi))
                    mutex.withLock { memory = result; retryAfter = 0 }
                    // A full disk must not turn successful hours into "unavailable".
                    runCatching { writeCacheAtomically(cacheFile, adapter.toJson(result).toByteArray()) }
                    result
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    mutex.withLock {
                        retryAfter = nowMillis() + RETRY_DELAY
                        memory?.takeIf(::isFresh)
                    }
                } finally {
                    withContext(NonCancellable) { mutex.withLock { refreshTask = null } }
                }
            }.also { refreshTask = it }
        }
        task.await()
    }

    private fun isFresh(cache: Cache): Boolean =
        cache.schemaVersion == 2 && nowMillis() - cache.fetchedAt in 0 until CACHE_LIFETIME

    companion object {
        const val CACHE_LIFETIME = 7L * 24 * 60 * 60 * 1000
        const val RETRY_DELAY = 15L * 60 * 1000
    }
}

internal fun writeCacheAtomically(file: File, bytes: ByteArray) {
    file.parentFile?.mkdirs()
    val temporary = File.createTempFile(file.name, ".tmp", file.parentFile)
    try {
        temporary.writeBytes(bytes)
        java.nio.file.Files.move(temporary.toPath(), file.toPath(),
            java.nio.file.StandardCopyOption.REPLACE_EXISTING, java.nio.file.StandardCopyOption.ATOMIC_MOVE)
    } finally {
        temporary.delete()
    }
}

private suspend fun fetchPennStateHours(): String = withContext(Dispatchers.IO) {
    val connection = URI("https://liveon.prod.fbweb.psu.edu/json/up/hours").toURL().openConnection() as HttpURLConnection
    try {
        connection.connectTimeout = 15_000
        connection.readTimeout = 20_000
        if (connection.responseCode !in 200..299) error("Hours HTTP ${connection.responseCode}")
        connection.inputStream.bufferedReader().use { it.readText() }
    } finally { connection.disconnect() }
}
