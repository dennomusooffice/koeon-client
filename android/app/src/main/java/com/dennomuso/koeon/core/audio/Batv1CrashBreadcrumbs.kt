package com.dennomuso.koeon.core.audio

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

const val BATV1_BREADCRUMB_MAX_EVENTS = 64

enum class PreviousRunTermination {
    CLEAN,
    UNEXPECTED_TERMINATION_OR_KILL,
    UNKNOWN,
}

data class Batv1CrashBreadcrumb(
    val timestampEpochMs: Long,
    val platform: String,
    val build: String,
    val generationToken: String?,
    val role: String,
    val stage: String,
    val threadClass: String,
    val resultClass: String,
)

internal class Batv1BreadcrumbRing(private val capacity: Int = BATV1_BREADCRUMB_MAX_EVENTS) {
    private val events = ArrayDeque<Batv1CrashBreadcrumb>()

    fun append(event: Batv1CrashBreadcrumb) {
        while (events.size >= capacity) events.removeFirst()
        events.addLast(event)
    }

    fun replace(values: List<Batv1CrashBreadcrumb>) {
        events.clear()
        values.takeLast(capacity).forEach(::append)
    }

    fun snapshot(): List<Batv1CrashBreadcrumb> = events.toList()
}

/**
 * Process-global, bounded, non-audio breadcrumb store. Values are deliberately
 * restricted to lifecycle classifications; PCM, credentials and full IDs are
 * never accepted by this API.
 */
object Batv1CrashBreadcrumbs {
    private const val preferencesName = "koeon_batv1_crash_breadcrumbs"
    private const val eventsKey = "events_v1"
    private const val runKnownKey = "run_known"
    private const val cleanExitKey = "clean_exit"
    private val lock = Any()
    private val ring = Batv1BreadcrumbRing()
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
            ring.append(
                Batv1CrashBreadcrumb(
                    timestampEpochMs = System.currentTimeMillis(),
                    platform = "android",
                    build = build,
                    generationToken = generationId?.take(8),
                    role = role.take(8),
                    stage = stage.take(64),
                    threadClass = threadClass.take(32),
                    resultClass = resultClass.take(64),
                ),
            )
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
    fun snapshot(): List<Batv1CrashBreadcrumb> = synchronized(lock) { ring.snapshot() }

    private fun encode(events: List<Batv1CrashBreadcrumb>): String = JSONArray().also { array ->
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

    private fun decode(raw: String?): List<Batv1CrashBreadcrumb> = runCatching {
        val array = JSONArray(raw ?: "[]")
        buildList {
            for (index in 0 until array.length()) {
                val value = array.getJSONObject(index)
                add(
                    Batv1CrashBreadcrumb(
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
