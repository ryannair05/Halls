package com.ryannair05.meetandeat.dining

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Replay the latest cumulative preview to every caller, including callers joining an existing load. */
internal class MenuRequests(private val scope: CoroutineScope) {
    private class Request(val progress: MutableStateFlow<MenuDaySnapshot?>, val result: Deferred<MenuDaySnapshot>)
    private val mutex = Mutex()
    private val requests = mutableMapOf<String, Request>()

    suspend fun load(
        key: String,
        onPartial: suspend (MenuDaySnapshot) -> Unit,
        fetch: suspend (suspend (MenuDaySnapshot) -> Unit) -> MenuDaySnapshot,
    ): MenuDaySnapshot = coroutineScope {
        val request = mutex.withLock {
            requests.entries.removeAll { it.value.result.isCompleted }
            requests.getOrPut(key) {
                val progress = MutableStateFlow<MenuDaySnapshot?>(null)
                Request(progress, scope.async { fetch { progress.value = it } })
            }
        }
        val observer = launch(start = CoroutineStart.UNDISPATCHED) {
            request.progress.filterNotNull().collect { onPartial(it) }
        }
        try {
            request.result.await()
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            observer.cancelAndJoin()
            request.progress.value?.let { onPartial(it) }
            throw error
        } finally {
            observer.cancel()
            withContext(NonCancellable) {
                observer.join()
                mutex.withLock {
                    if (request.result.isCompleted && requests[key] === request) requests.remove(key)
                }
            }
        }
    }
}
