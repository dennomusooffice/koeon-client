package com.dennomuso.koeon.core.audio

import java.util.ArrayDeque

/** Memory-only FIFO before Opus encoding. One capture tick emits at most one tick.
 * Never mixes recorded and live samples or silently drops the beginning on overflow.
 * The owner must stop publication on [failure]; no network work runs on this callback.
 */
class RtpPreRollBuffer(private val maximumMilliseconds: Int = 6000) {
    private val frames = ArrayDeque<ByteArray>()
    private var format: String? = null
    private var durationUs = 0L
    private var armed = false
    private var collecting = false
    private var emitting = false
    private var confirmed = false
    @Volatile var failure: String? = null
        private set

    @Synchronized fun arm() {
        clear()
        armed = true
        collecting = true
    }

    @Synchronized fun markCueBoundary(): Boolean {
        if (!armed || !confirmed || failure != null) return false
        frames.clear()
        durationUs = 0
        return true
    }

    /** Enable only AFTER floor/readiness and successful track publication. */
    @Synchronized fun authorize(): Boolean {
        if (!armed || !confirmed || failure != null) return false
        emitting = true
        return true
    }

    @Synchronized fun freeze() { collecting = false }
    @Synchronized fun isConfirmed() = confirmed && failure == null
    @Synchronized fun isCollecting() = armed && collecting && failure == null
    @Synchronized fun isDrained() = !collecting && frames.isEmpty()
    @Synchronized fun pendingMilliseconds() = durationUs / 1000

    @Synchronized fun clear() {
        frames.clear()
        format = null
        durationUs = 0
        armed = false
        collecting = false
        emitting = false
        confirmed = false
        failure = null
    }

    /** The returned PCM replaces the SDK microphone buffer; it is never added to it. */
    @Synchronized fun process(input: ByteArray, sampleRate: Int, channels: Int, bytesPerSample: Int): ByteArray {
        val silence = ByteArray(input.size)
        if (!armed || failure != null) return silence
        if (sampleRate <= 0 || channels <= 0 || bytesPerSample <= 0 || input.isEmpty() ||
            input.size % (channels * bytesPerSample) != 0) {
            failure = "RTP_CAPTURE_FORMAT_INVALID"
            return silence
        }
        val nextFormat = "$sampleRate:$channels:$bytesPerSample:${input.size}"
        if (format != null && format != nextFormat) {
            // Do not reinterpret old PCM after a Bluetooth/route change.
            failure = "RTP_CAPTURE_FORMAT_CHANGED"
            frames.clear()
            durationUs = 0
            return silence
        }
        format = nextFormat
        val tickUs = input.size.toLong() * 1_000_000 / (sampleRate * channels * bytesPerSample)
        confirmed = true
        if (collecting) {
            if (durationUs + tickUs > maximumMilliseconds * 1000L) {
                failure = "RTP_PREROLL_CAPACITY_EXCEEDED"
                frames.clear()
                durationUs = 0
                return silence
            }
            frames.addLast(input.copyOf())
            durationUs += tickUs
        }
        if (!emitting || frames.isEmpty()) return silence
        durationUs -= tickUs
        return frames.removeFirst()
    }
}
