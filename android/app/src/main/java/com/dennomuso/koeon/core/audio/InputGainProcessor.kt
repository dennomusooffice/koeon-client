package com.dennomuso.koeon.core.audio

import android.content.SharedPreferences
import io.livekit.android.audio.AudioProcessorInterface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Instant
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sqrt

enum class InputGainMode { OFF, AUTO, MANUAL }

data class AudioDeviceProfile(
    val profileId: String,
    val displayName: String,
    val routeType: String,
    val manualGainDb: Float = 0f,
    val autoTrimDb: Float = 0f,
    val calibratedAt: String? = null,
    val measuredSpeechRmsDbfs: Float? = null,
    val measuredPeakDbfs: Float? = null,
    val measuredNoiseFloorDbfs: Float? = null,
    val lastAppliedGainDb: Float = 0f,
)

data class InputGainSnapshot(
    val route: String = "Unavailable",
    val mode: InputGainMode = InputGainMode.OFF,
    val manualGainDb: Float = 0f,
    val autoTrimDb: Float = 0f,
    val effectiveGainDb: Float = 0f,
    val inputRmsDbfs: Float? = null,
    val inputPeakDbfs: Float? = null,
    val postKoeonRmsDbfs: Float? = null,
    val postKoeonPeakDbfs: Float? = null,
    val limiterHitCount: Long = 0,
    val calibrationState: String = "IDLE",
    val recommendedGainDb: Float? = null,
)

interface AudioDeviceProfileRepository {
    fun load(route: String): AudioDeviceProfile
    fun save(profile: AudioDeviceProfile)
    fun reset(route: String)
}

class AudioDeviceProfileStore(private val preferences: SharedPreferences) : AudioDeviceProfileRepository {
    override fun load(route: String): AudioDeviceProfile {
        val id = routeKey(route)
        return AudioDeviceProfile(
            profileId = id,
            displayName = route,
            routeType = route.substringBefore(':'),
            manualGainDb = preferences.getFloat("$id.manual", 0f),
            autoTrimDb = preferences.getFloat("$id.auto", 0f),
            calibratedAt = preferences.getString("$id.calibratedAt", null),
            measuredSpeechRmsDbfs = floatOrNull("$id.rms"),
            measuredPeakDbfs = floatOrNull("$id.peak"),
            measuredNoiseFloorDbfs = floatOrNull("$id.noise"),
            lastAppliedGainDb = preferences.getFloat("$id.last", 0f),
        )
    }

    override fun save(profile: AudioDeviceProfile) {
        preferences.edit()
            .putFloat("${profile.profileId}.manual", profile.manualGainDb)
            .putFloat("${profile.profileId}.auto", profile.autoTrimDb)
            .putString("${profile.profileId}.calibratedAt", profile.calibratedAt)
            .apply {
                profile.measuredSpeechRmsDbfs?.let { putFloat("${profile.profileId}.rms", it) }
                profile.measuredPeakDbfs?.let { putFloat("${profile.profileId}.peak", it) }
                profile.measuredNoiseFloorDbfs?.let { putFloat("${profile.profileId}.noise", it) }
            }
            .putFloat("${profile.profileId}.last", profile.lastAppliedGainDb)
            .apply()
    }

    override fun reset(route: String) {
        val id = routeKey(route)
        preferences.edit().also { editor ->
            listOf("manual", "auto", "calibratedAt", "rms", "peak", "noise", "last")
                .forEach { editor.remove("$id.$it") }
        }.apply()
    }

    private fun floatOrNull(key: String): Float? = if (preferences.contains(key)) preferences.getFloat(key, 0f) else null
    private fun routeKey(route: String) = "gain.${route.lowercase().replace(Regex("[^a-z0-9]+"), "_").take(80)}"

}

class InputGainProcessor(
    private val profileStore: AudioDeviceProfileRepository? = null,
    initialMode: InputGainMode = InputGainMode.OFF,
    private val onSnapshot: (InputGainSnapshot) -> Unit = {},
) : AudioProcessorInterface {
    private var mode = initialMode
    private var route = "Unavailable"
    private var profile = AudioDeviceProfile("gain.unavailable", route, "unknown")
    private var transmissionActive = false
    private var fixedTransmissionGainDb = 0f
    private var sumSquares = 0.0
    private var sampleCount = 0L
    private var peak = 0f
    private var postSumSquares = 0.0
    private var postPeak = 0f
    private var limiterHits = 0L
    private var calibrationUntilMs: Long? = null
    private val calibrationFrameRms = mutableListOf<Float>()
    private var recommendation: Float? = null

    override fun isEnabled() = true
    override fun getName() = "koeon_input_gain_v1"
    override fun initializeAudioProcessing(sampleRateHz: Int, numChannels: Int) = Unit
    override fun resetAudioProcessing(newRate: Int) = Unit

    @Synchronized
    fun setRoute(value: String) {
        if (value == route) return
        route = value
        profile = profileStore?.load(value) ?: AudioDeviceProfile("gain.$value", value, value.substringBefore(':'))
        resetUtterance()
        publish()
    }

    @Synchronized fun setMode(value: InputGainMode) { mode = value; publish() }
    @Synchronized fun setManualGainDb(value: Float) { profile = profile.copy(manualGainDb = value.coerceIn(-6f, 12f)); profileStore?.save(profile); publish() }

    @Synchronized
    fun beginTransmission() {
        transmissionActive = true
        fixedTransmissionGainDb = effectiveGainDb()
        resetUtterance()
        publish()
    }

    @Synchronized
    fun endTransmission() {
        transmissionActive = false
        if (mode == InputGainMode.AUTO && sampleCount >= 4_800) {
            val rms = rmsDbfs()
            if (rms != null) {
                val limiterRatio = limiterHits.toDouble() / sampleCount.toDouble()
                profile = profile.copy(
                    autoTrimDb = nextAutoTrim(
                        current = profile.autoTrimDb,
                        speechRmsDbfs = rms,
                        inputPeakDbfs = dbfs(peak),
                        limiterRatio = limiterRatio,
                    ),
                    lastAppliedGainDb = fixedTransmissionGainDb,
                )
                profileStore?.save(profile)
            }
        }
        publish()
    }

    @Synchronized
    fun startCalibration(nowMs: Long = System.currentTimeMillis()) {
        calibrationFrameRms.clear()
        recommendation = null
        calibrationUntilMs = nowMs + 3_000
        publish()
    }

    @Synchronized
    fun resetProfile() {
        profileStore?.reset(route)
        profile = profileStore?.load(route) ?: profile.copy(manualGainDb = 0f, autoTrimDb = 0f, calibratedAt = null)
        recommendation = null
        publish()
    }

    @Synchronized fun snapshot() = makeSnapshot()

    @Synchronized
    override fun processAudio(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        val gainDb = if (transmissionActive) fixedTransmissionGainDb else effectiveGainDb()
        val multiplier = 10.0.pow(gainDb / 20.0).toFloat()
        val processingEnabled = mode != InputGainMode.OFF
        val view = buffer.duplicate().order(ByteOrder.nativeOrder())
        view.rewind()
        var frameSquare = 0.0
        var framePeak = 0f
        var count = 0
        while (view.remaining() >= 2) {
            val position = view.position()
            val input = view.short.toInt()
            val normalized = input / 32768f
            frameSquare += normalized * normalized
            framePeak = maxOf(framePeak, abs(normalized))
            if (processingEnabled) {
                var output = normalized * multiplier
                val limited = softLimit(output)
                if (limited != output) limiterHits++
                output = limited
                view.putShort(position, (output * 32767f).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort())
                postSumSquares += output * output
                postPeak = maxOf(postPeak, abs(output))
            } else {
                postSumSquares += normalized * normalized
                postPeak = maxOf(postPeak, abs(normalized))
            }
            count++
        }
        if (count > 0) {
            sumSquares += frameSquare
            sampleCount += count
            peak = maxOf(peak, framePeak)
            val frameRms = sqrt(frameSquare / count).toFloat()
            calibrationUntilMs?.let { deadline ->
                calibrationFrameRms += dbfs(frameRms)
                if (System.currentTimeMillis() >= deadline) finishCalibration()
            }
        }
        // Realtime callback performs no UI dispatch or per-frame snapshot allocation.
    }

    private fun finishCalibration() {
        calibrationUntilMs = null
        val voiced = calibrationFrameRms.filter { it > -45f }
        if (voiced.size < 10) { recommendation = null; publish(); return }
        val speech = voiced.average().toFloat()
        val noise = calibrationFrameRms.sorted().take(maxOf(1, calibrationFrameRms.size / 5)).average().toFloat()
        recommendation = recommendedGain(speech)
        profile = profile.copy(
            autoTrimDb = recommendation!!,
            calibratedAt = Instant.now().toString(),
            measuredSpeechRmsDbfs = speech,
            measuredPeakDbfs = dbfs(peak),
            measuredNoiseFloorDbfs = noise,
        )
        profileStore?.save(profile)
        publish()
    }

    private fun effectiveGainDb() = when (mode) {
        InputGainMode.OFF -> 0f
        InputGainMode.MANUAL -> profile.manualGainDb
        InputGainMode.AUTO -> profile.autoTrimDb
    }.coerceIn(-6f, 12f)

    private fun rmsDbfs(): Float? = if (sampleCount == 0L) null else dbfs(sqrt(sumSquares / sampleCount).toFloat())
    private fun dbfs(value: Float) = if (value <= 0f) -120f else (20f * log10(value)).coerceAtLeast(-120f)
    private fun softLimit(value: Float): Float {
        val sign = if (value < 0) -1f else 1f
        val magnitude = abs(value)
        val knee = 0.75f
        val ceiling = 0.89125f
        if (magnitude <= knee) return value
        val compressed = knee + (ceiling - knee) * (1f - exp(-(magnitude - knee) / (ceiling - knee)))
        return sign * minOf(ceiling, compressed)
    }

    private fun resetUtterance() { sumSquares = 0.0; postSumSquares = 0.0; sampleCount = 0; peak = 0f; postPeak = 0f; limiterHits = 0 }
    private fun makeSnapshot() = InputGainSnapshot(
        route = route, mode = mode, manualGainDb = profile.manualGainDb, autoTrimDb = profile.autoTrimDb,
        effectiveGainDb = if (transmissionActive) fixedTransmissionGainDb else effectiveGainDb(),
        inputRmsDbfs = rmsDbfs(), inputPeakDbfs = if (sampleCount > 0) dbfs(peak) else null,
        postKoeonRmsDbfs = if (sampleCount > 0) dbfs(sqrt(postSumSquares / sampleCount).toFloat()) else null,
        postKoeonPeakDbfs = if (sampleCount > 0) dbfs(postPeak) else null,
        limiterHitCount = limiterHits,
        calibrationState = if (calibrationUntilMs == null) "IDLE" else "MEASURING",
        recommendedGainDb = recommendation,
    )
    private fun publish() = onSnapshot(makeSnapshot())

    companion object {
        internal fun recommendedGain(speechRmsDbfs: Float): Float =
            (-18f - speechRmsDbfs).coerceIn(-6f, 12f)

        internal fun nextAutoTrim(current: Float, speechRmsDbfs: Float): Float =
            (current + (-18f - speechRmsDbfs).coerceIn(-1f, 1f)).coerceIn(-6f, 12f)

        internal fun nextAutoTrim(
            current: Float,
            speechRmsDbfs: Float,
            inputPeakDbfs: Float,
            limiterRatio: Double,
        ): Float {
            // Platform/WebRTC AGC runs before this optional trim. Persistent
            // full-scale input or limiter activity must pull AUTO down, never
            // become a condition that freezes an excessive positive profile.
            if (inputPeakDbfs >= -0.5f || limiterRatio >= 0.01) {
                return (current - 1f).coerceAtLeast(-6f)
            }
            return nextAutoTrim(current, speechRmsDbfs)
        }
    }
}
