package com.ryannair05.meetandeat.cata

import com.ryannair05.meetandeat.dining.writeCacheAtomically
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.coroutines.*
import java.io.File

/** Delivers a saved catalog before touching the network. Disk failure cannot discard a live result. */
internal class CataRouteCatalog(
    private val file: File,
    private val now: () -> Long = System::currentTimeMillis,
    private val fetch: suspend () -> List<RouteModel>,
) {
    @Serializable
    private data class Cache(val fetchedAt: Long, val routes: List<RouteModel>)
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun load(force: Boolean, publish: suspend (List<RouteModel>) -> Unit) {
        val cached = withContext(Dispatchers.IO) {
            runCatching { json.decodeFromString<Cache>(file.readText()) }.getOrNull()
                ?.takeIf { it.routes.isNotEmpty() && it.routes.all(::validRoute) }
        }
        if (cached != null) publish(cached.routes.sortedBy(RouteModel::sort))
        if (!force && cached != null && now() - cached.fetchedAt in 0 until MAXIMUM_AGE) return
        val routes = withContext(Dispatchers.IO) {
            fetch().filter(::validRoute).sortedBy(RouteModel::sort)
                .also { require(it.isNotEmpty()) { "Empty route catalog" } }
        }
        publish(routes)
        withContext(Dispatchers.IO) {
            runCatching { writeCacheAtomically(file, json.encodeToString(Cache.serializer(), Cache(now(), routes)).toByteArray()) }
        }
    }

    private fun validRoute(route: RouteModel) = route.routeId > 0 && route.kml.isNotBlank()
    companion object { const val MAXIMUM_AGE = 60 * 60 * 1000L }
}

/** Confined to the owning UI scope. Metadata refresh must not restart unchanged route work. */
internal class SelectedRouteRequests(
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val jobs = mutableMapOf<String, Job>()
    private val completed = mutableMapOf<String, Pair<Int, Long>>()

    fun start(key: String, routeId: Int, force: Boolean = false, load: suspend () -> Boolean) {
        val saved = completed[key]
        if (jobs[key]?.isActive == true || (!force && saved?.first == routeId && isCataGeometryFresh(saved.second, now()))) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            val success = load()
            ensureActive()
            if (success) completed[key] = routeId to now()
        }
        jobs[key] = job
        job.start()
    }

    fun cancel(key: String) {
        jobs.remove(key)?.cancel()
        completed.remove(key)
    }
}

// Static route geometry follows the operational catalog's one-hour refresh window.
internal fun isCataGeometryFresh(savedAt: Long, now: Long): Boolean =
    savedAt > 0 && now - savedAt in 0 until CataRouteCatalog.MAXIMUM_AGE
