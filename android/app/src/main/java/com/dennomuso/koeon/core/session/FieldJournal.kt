package com.dennomuso.koeon.core.session

import android.content.Context
import android.os.SystemClock
import com.dennomuso.koeon.BuildConfig
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Bounded writer: never blocks audio/UI on disk or export. */
class FieldJournal(context: Context) {
    private val prefs = context.getSharedPreferences("field_journal", Context.MODE_PRIVATE)
    private val installation = prefs.getString("installation", null) ?: UUID.randomUUID().toString().also {
        prefs.edit().putString("installation", it).apply()
    }
    private val store by lazy { FieldJournalStore(File(context.noBackupFilesDir, "field-journal"), "android",
        "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", installation) }
    private val exportFile = File(context.filesDir, "KOEONDiagnostics/field-journal-export.json")
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, ArrayBlockingQueue(256),
        { r -> Thread(r, "koeon-field-journal").apply { isDaemon = true } })
    private val admission = FieldJournalAdmission()
    fun record(event: String, fields: Map<String, Any?> = emptyMap(), ids: Map<String, String?> = emptyMap()) {
        val wall = System.currentTimeMillis(); val mono = SystemClock.elapsedRealtime()
        if (!admission.admit()) return
        try { worker.execute {
            try { store.append(event, fields, ids, wall, mono, admission.takeDropped()) }
            finally { admission.finish() }
        } } catch (_: RejectedExecutionException) { admission.finish() }
    }
    suspend fun export(): File = suspendCancellableCoroutine { continuation ->
        try {
            worker.execute {
                if (continuation.isActive) {
                    try { val file = store.export(exportFile, System.currentTimeMillis()); if (continuation.isActive) continuation.resume(file) }
                    catch (error: Exception) { if (continuation.isActive) continuation.resumeWithException(error) }
                }
            }
        } catch (error: RejectedExecutionException) { continuation.resumeWithException(error) }
    }
}
