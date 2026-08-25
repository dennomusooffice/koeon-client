package com.dennomuso.koeon.core.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.SystemClock
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import com.dennomuso.koeon.core.ptt.PttCuePlayer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.PI
import kotlin.math.sin

internal const val PTT_CUE_AUDIO_USAGE = AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING

internal enum class CueRole { TX, RX }

internal class StatusCueRateLimiter(
    private val nowMillis: () -> Long,
    private val minimumIntervalMs: Long = 500L,
) {
    private val lock = Any()
    private val lastAt = mutableMapOf<String, Long>()

    fun accept(type: String): Boolean = synchronized(lock) {
        val now = nowMillis()
        val last = lastAt[type]
        if (last != null && now - last < minimumIntervalMs) false
        else { lastAt[type] = now; true }
    }
}

internal class TonePttCuePlayer(
    context: Context? = null,
    private val role: CueRole = CueRole.TX,
    private val statusRateLimiter: StatusCueRateLimiter = StatusCueRateLimiter(SystemClock::elapsedRealtime),
) : PttCuePlayer {
    private val vibrator: Vibrator? = context?.let {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            it.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            it.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    override suspend fun playStart(): Result<Unit> = if (role == CueRole.TX) {
        play(listOf(Tone(TX_START_FREQUENCY_HZ, TX_CUE_DURATION_MS)), TX_RX_VOLUME)
    } else {
        play(listOf(Tone(RX_START_FREQUENCY_HZ, RX_CUE_DURATION_MS)), TX_RX_VOLUME)
    }

    override suspend fun playEnd(): Result<Unit> = if (role == CueRole.TX) {
        play(listOf(Tone(TX_END_FREQUENCY_HZ, TX_CUE_DURATION_MS)), TX_RX_VOLUME)
    } else {
        play(listOf(Tone(RX_END_FREQUENCY_HZ, RX_CUE_DURATION_MS)), TX_RX_VOLUME)
    }

    override suspend fun playBusy(): Result<Unit> = playStatus(
        "busy",
        listOf(
            Tone(BUSY_FREQUENCY_HZ, 100), Tone(0.0, 60),
            Tone(BUSY_FREQUENCY_HZ, 100), Tone(0.0, 60), Tone(BUSY_FREQUENCY_HZ, 100),
        ),
        BUSY_VOLUME,
    )

    override suspend fun playError(): Result<Unit> = playStatus(
        "error",
        listOf(
            Tone(ERROR_HIGH_FREQUENCY_HZ, 140), Tone(0.0, 50),
            Tone(ERROR_MID_FREQUENCY_HZ, 140), Tone(0.0, 50), Tone(ERROR_LOW_FREQUENCY_HZ, 200),
        ),
        ERROR_VOLUME,
    )

    private suspend fun playStatus(type: String, tones: List<Tone>, volume: Float): Result<Unit> {
        if (!statusRateLimiter.accept(type)) return Result.success(Unit)
        vibrateStatus(type)
        return play(tones, volume)
    }

    private suspend fun play(tones: List<Tone>, volume: Float): Result<Unit> = try {
        playCue(tones, volume)
        Result.success(Unit)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Log.w(TAG, "PTT cue playback failed: ${error.javaClass.simpleName}: ${error.message}")
        Result.failure(error)
    }

    private suspend fun playCue(tones: List<Tone>, volume: Float) {
        val samples = tones.flatMap { makeCue(it.frequencyHz, it.durationMs).asIterable() }.toShortArray()
        val player = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(PTT_CUE_AUDIO_USAGE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE_HZ)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(samples.size * Short.SIZE_BYTES)
            .build()
        try {
            // MODE_STATIC is STATE_NO_STATIC_DATA until its first successful write.
            check(
                player.state == AudioTrack.STATE_NO_STATIC_DATA ||
                    player.state == AudioTrack.STATE_INITIALIZED,
            ) { "PTT cue AudioTrack did not initialize (state=${player.state})" }
            check(
                player.write(samples, 0, samples.size, AudioTrack.WRITE_BLOCKING) == samples.size,
            ) { "PTT cue write failed" }
            check(player.state == AudioTrack.STATE_INITIALIZED) {
                "PTT cue AudioTrack did not become ready after write (state=${player.state})"
            }
            player.setVolume(volume.coerceIn(0f, 1f))
            player.play()
            check(player.playState == AudioTrack.PLAYSTATE_PLAYING) {
                "PTT cue AudioTrack did not start (playState=${player.playState})"
            }
            val durationMs = tones.sumOf { it.durationMs }
            val completed = withTimeoutOrNull(durationMs + PLAYBACK_TIMEOUT_MARGIN_MS) {
                while (player.playbackHeadPosition < samples.size) {
                    delay(PLAYBACK_POLL_INTERVAL_MS)
                }
                true
            } ?: false
            check(completed) {
                "PTT cue playback timed out (frames=${player.playbackHeadPosition}/${samples.size})"
            }
        } finally {
            runCatching { player.stop() }
            player.release()
        }
    }

    private fun vibrateStatus(type: String) {
        val current = vibrator?.takeIf { it.hasVibrator() } ?: return
        val effect = if (type == "busy") {
            VibrationEffect.createWaveform(longArrayOf(0, 55, 50, 55), intArrayOf(0, 150, 0, 150), -1)
        } else {
            VibrationEffect.createWaveform(
                longArrayOf(0, 70, 45, 85, 45, 120),
                intArrayOf(0, 190, 0, 220, 0, 255),
                -1,
            )
        }
        runCatching { current.vibrate(effect) }
    }

    internal fun makeCue(frequencyHz: Double, durationMs: Long = RX_CUE_DURATION_MS): ShortArray {
        val count = (SAMPLE_RATE_HZ * durationMs / 1_000L).toInt()
        val fadeSamples = (SAMPLE_RATE_HZ * FADE_MS / 1_000L).toInt()
        return ShortArray(count) { index ->
            if (frequencyHz <= 0.0) return@ShortArray 0
            val fade = when {
                index < fadeSamples -> index.toDouble() / fadeSamples
                index >= count - fadeSamples -> (count - index - 1).coerceAtLeast(0).toDouble() / fadeSamples
                else -> 1.0
            }
            (sin(2.0 * PI * frequencyHz * index / SAMPLE_RATE_HZ) * Short.MAX_VALUE * fade).toInt().toShort()
        }
    }

    companion object {
        const val TX_CUE_DURATION_MS = 100L
        const val RX_CUE_DURATION_MS = 95L
        const val TX_START_FREQUENCY_HZ = 1_350.0
        const val TX_END_FREQUENCY_HZ = 850.0
        const val RX_START_FREQUENCY_HZ = 1_100.0
        const val RX_END_FREQUENCY_HZ = 700.0
        const val BUSY_FREQUENCY_HZ = 600.0
        const val ERROR_HIGH_FREQUENCY_HZ = 1_000.0
        const val ERROR_MID_FREQUENCY_HZ = 700.0
        const val ERROR_LOW_FREQUENCY_HZ = 400.0
        const val TX_RX_VOLUME = 0.38f
        const val BUSY_VOLUME = 0.50f
        const val ERROR_VOLUME = 0.63f
        private const val SAMPLE_RATE_HZ = 16_000
        private const val FADE_MS = 4
        private const val PLAYBACK_POLL_INTERVAL_MS = 5L
        private const val PLAYBACK_TIMEOUT_MARGIN_MS = 250L
        private const val TAG = "TonePttCuePlayer"
    }

    private data class Tone(val frequencyHz: Double, val durationMs: Long)
}
