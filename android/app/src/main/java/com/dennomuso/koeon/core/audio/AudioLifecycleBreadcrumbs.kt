package com.dennomuso.koeon.core.audio

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

const val AUDIO_BREADCRUMB_MAX_EVENTS = 64

enum class PreviousRunTermination {
    CLEAN,
    UNEXPECTED_TERMINATION_OR_KILL,
    UNKNOWN,
}

data class AudioLifecycleBreadcrumb(
    val timestampEpochMs: Long,
    val platform: String,
    val build: String,
    val generationToken: String?,
    val role: String,
    val stage: String,
    val threadClass: String,
    val resultClass: String,
)

internal class AudioLifecycleBreadcrumbRing(private val capacity: Int = AUDIO_BREADCRUMB_MAX_EVENTS) {
    private val events = ArrayDeque<AudioLifecycleBreadcrumb>()
    // Full generation IDs are retained only in this bounded in-memory window.
    private val recordedPolls = LinkedHashSet<Pair<String, String>>()

    fun append(event: AudioLifecycleBreadcrumb, generationId: String? = null): Boolean {
        if (event.role == "RX" && event.resultClass == "OK" && generationId != null &&
            event.stage in setOf("RX_SUBSCRIBE_BEGIN", "RX_SUBSCRIBE_END")) {
            val key = generationId to event.stage
            if (key in recordedPolls) return false
            if (recordedPolls.size >= AUDIO_BREADCRUMB_MAX_EVENTS) {
                recordedPolls.remove(recordedPolls.first())
            }
            recordedPolls.add(key)
        }
        while (events.size >= capacity) events.removeFirst()
        events.addLast(event)
        return true
    }

    fun replace(values: List<AudioLifecycleBreadcrumb>) {
        events.clear()
        recordedPolls.clear()
        values.takeLast(capacity).forEach { append(it) }
    }

    fun snapshot(): List<AudioLifecycleBreadcrumb> = events.toList()
}

/**
 * Process-global, bounded, non-audio breadcrumb store. Values are deliberately
 * restricted to lifecycle classifications. PCM and credentials are never stored;
 * full generation IDs are used only for bounded in-memory coalescing.
 */
object AudioLifecycleBreadcrumbs {
    // Preserve diagnostic history across upgrades; this storage key is not a transport.
    private const val preferencesName = "koeon_batv1_crash_breadcrumbs"
    private const val eventsKey = "events_v1"
    private const val runKnownKey = "run_known"
    private const val cleanExitKey = "clean_exit"
    private val lock = Any()
    private val ring = AudioLifecycleBreadcrumbRing()
    private var initialized = false
    private var build = "unknown"
    private var previousRun = PreviousRunTermination.UNKNOWN
    private var preferences: android.content.SharedPreferences? = null

    fun initialize(context: Context, build: String) {
        synchronized(lock) {
            if (initialized) return
            this.build = build.take(64)
            preferences = context.applicationContext.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            val prefs = preferences ?: return
            previousRun = when {
                !prefs.getBoolean(runKnownKey, false) -> PreviousRunTermination.UNKNOWN
                prefs.getBoolean(cleanExitKey, false) -> PreviousRunTermination.CLEAN
                else -> PreviousRunTermination.UNEXPECTED_TERMINATION_OR_KILL
            }
            ring.replace(decode(prefs.getString(eventsKey, null)))
            initialized = true
            prefs.edit().putBoolean(runKnownKey, true).putBoolean(cleanExitKey, false).commit()
        }
        record(role = "APP", stage = "APP_START", resultClass = "OK")
    }

    fun record(
        role: String,
        stage: String,
        generationId: String? = null,
        threadClass: String = currentThreadClass(),
        resultClass: String = "OK",
    ) {
        synchronized(lock) {
            if (!initialized) return
            if (!ring.append(
                AudioLifecycleBreadcrumb(
                    timestampEpochMs = System.currentTimeMillis(),
                    platform = "android",
                    build = build,
                    generationToken = generationId?.take(8),
                    role = role.take(8),
                    stage = stage.take(64),
                    threadClass = threadClass.take(32),
                    resultClass = resultClass.take(64),
                ),
                generationId = generationId,
            )) return
            preferences?.edit()
                ?.putString(eventsKey, encode(ring.snapshot()))
                ?.putBoolean(cleanExitKey, false)
                ?.apply()
        }
    }

    fun markCleanExit() {
        record(role = "APP", stage = "APP_CLEAN_EXIT", resultClass = "OK")
        synchronized(lock) { preferences?.edit()?.putBoolean(cleanExitKey, true)?.commit() }
    }

    fun previousRunTermination(): PreviousRunTermination = synchronized(lock) { previousRun }
    fun snapshot(): List<AudioLifecycleBreadcrumb> = synchronized(lock) { ring.snapshot() }

    private fun encode(events: List<AudioLifecycleBreadcrumb>): String = JSONArray().also { array ->
        events.forEach { event ->
            array.put(JSONObject().apply {
                put("timestamp", event.timestampEpochMs)
                put("platform", event.platform)
                put("build", event.build)
                put("generation", event.generationToken ?: JSONObject.NULL)
                put("role", event.role)
                put("stage", event.stage)
                put("thread", event.threadClass)
                put("result", event.resultClass)
            })
        }
    }.toString()

    private fun decode(raw: String?): List<AudioLifecycleBreadcrumb> = runCatching {
        val array = JSONArray(raw ?: "[]")
        buildList {
            for (index in 0 until array.length()) {
                val value = array.getJSONObject(index)
                add(
                    AudioLifecycleBreadcrumb(
                        timestampEpochMs = value.optLong("timestamp"),
                        platform = value.optString("platform", "android"),
                        build = value.optString("build", "unknown"),
                        generationToken = value.optString("generation").takeIf { it.isNotBlank() && it != "null" },
                        role = value.optString("role", "UNKNOWN"),
                        stage = value.optString("stage", "UNKNOWN"),
                        threadClass = value.optString("thread", "UNKNOWN"),
                        resultClass = value.optString("result", "UNKNOWN"),
                    ),
                )
            }
        }
    }.getOrDefault(emptyList())

    private fun currentThreadClass(): String = when {
        android.os.Looper.myLooper() == android.os.Looper.getMainLooper() -> "MAIN"
        Thread.currentThread().name.contains("DefaultDispatcher") -> "COROUTINE_WORKER"
        else -> "BACKGROUND"
    }
}
