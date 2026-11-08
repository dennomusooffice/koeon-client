package com.dennomuso.koeon.core.livekit

/** Metadata only: a PCM callback can contain silence/PLC and does not prove audibility. */
data class RemotePcmSnapshot(
    val observedTracks: Int = 0,
    val callbacks: Long = 0,
    val frames: Long = 0,
    val lastCallbackEpochMs: Long? = null,
    val lastSampleRate: Int? = null,
)

/** Tokens fence callbacks that arrive after unsubscribe or Room replacement. */
class RemotePcmDiagnostics {
    private var nextToken = 0L
    private val active = mutableSetOf<Long>()
    private var value = RemotePcmSnapshot()

    @Synchronized fun attach(): Long = (++nextToken).also { active.add(it) }
    @Synchronized fun detach(token: Long) { active.remove(token) }
    @Synchronized fun reset() { active.clear(); value = RemotePcmSnapshot() }

    @Synchronized fun record(token: Long, frames: Int, sampleRate: Int, epochMs: Long) {
        if (token !in active || frames <= 0 || sampleRate <= 0) return
        value = value.copy(
            callbacks = value.callbacks + 1,
            frames = value.frames + frames,
            lastCallbackEpochMs = epochMs,
            lastSampleRate = sampleRate,
        )
    }

    @Synchronized fun snapshot(): RemotePcmSnapshot = value.copy(observedTracks = active.size)
}
