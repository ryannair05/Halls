package com.ryannair05.meetandeat.journal

import android.content.Context
import android.util.AtomicFile
import androidx.annotation.MainThread
import com.ryannair05.meetandeat.dining.DiningMenuItem
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

data class PlateDraft(val key: String, val meal: JournalMeal, val sourceDate: String, val candidates: List<DiningMenuItem>)
data class PlateDraftFile(val version: Int = 1, val drafts: List<PlateDraft> = emptyList())

/** Drafts are not committed meals. Large food/detail graphs stay out of saved-instance-state bundles. */
class PlateDraftStore private constructor(context: Context) {
    private val file = AtomicFile(File(context.filesDir, "plate-drafts-v1.json"))
    private val adapter = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build().adapter(PlateDraftFile::class.java)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val writes = Channel<List<PlateDraft>>(Channel.CONFLATED)
    private var loaded = false
    private val mutableDrafts = MutableStateFlow<List<PlateDraft>>(emptyList())
    val drafts = mutableDrafts.asStateFlow()
    private val mutableError = MutableStateFlow<String?>(null)
    val error = mutableError.asStateFlow()

    init {
        scope.launch {
            for (snapshot in writes) {
                try {
                    mutex.withLock {
                        val output = file.startWrite()
                        try {
                            output.write(adapter.toJson(PlateDraftFile(drafts = snapshot)).toByteArray(Charsets.UTF_8))
                            file.finishWrite(output)
                        } catch (error: Throwable) { file.failWrite(output); throw error }
                    }
                    mutableError.value = null
                } catch (error: CancellationException) { throw error }
                catch (_: Exception) { mutableError.value = "Couldn't save your draft to this device. Your changes are still open." }
            }
        }
    }

    suspend fun load() = withContext(Dispatchers.IO) {
        mutex.withLock {
            if (loaded) return@withLock
            val saved = try { file.openRead().bufferedReader().use { requireNotNull(adapter.fromJson(it.readText())) } }
            catch (_: java.io.FileNotFoundException) { PlateDraftFile() }
            require(saved.version == 1) { "This draft needs a newer version of Halls." }
            mutableDrafts.value = saved.drafts
            loaded = true
        }
    }

    @MainThread fun update(draft: PlateDraft) {
        check(loaded)
        val next = mutableDrafts.value.filterNot { it.key == draft.key } + draft
        mutableDrafts.value = next
        writes.trySend(next)
    }

    @MainThread fun remove(key: String) {
        check(loaded)
        val next = mutableDrafts.value.filterNot { it.key == key }
        mutableDrafts.value = next
        writes.trySend(next)
    }

    companion object {
        @Volatile private var instance: PlateDraftStore? = null
        fun get(context: Context): PlateDraftStore = instance ?: synchronized(this) {
            instance ?: PlateDraftStore(context.applicationContext).also { instance = it }
        }
    }
}
