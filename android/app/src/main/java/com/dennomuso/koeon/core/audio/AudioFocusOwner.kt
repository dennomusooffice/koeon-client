package com.dennomuso.koeon.core.audio

enum class FocusSignal { GAIN, LOSS, TRANSIENT_LOSS, DUCK }

interface FocusRequester {
    fun request(onChange: (FocusSignal) -> Unit): Boolean
    fun abandon()
}

/** One focus owner per room. Permanent loss waits for explicit resume, never polling. */
class AudioFocusOwner(
    private val requester: FocusRequester,
    private val onGranted: () -> Unit,
    private val onLost: (String) -> Unit,
) {
    private var started = false
    private var generation = 0L
    @Volatile var hasFocus = false
        private set

    @Synchronized fun start() {
        if (started) return
        started = true
        request()
    }

    @Synchronized fun resume(): Boolean {
        if (!started) return false
        if (hasFocus) return true
        return request()
    }

    @Synchronized fun stop() {
        started = false
        generation++
        hasFocus = false
        requester.abandon()
    }

    private fun request(): Boolean {
        val ticket = ++generation
        requester.abandon()
        val granted = requester.request { signal -> changed(ticket, signal) }
        if (ticket != generation || !started) return false
        hasFocus = granted
        if (granted) {
            onGranted()
        } else {
            generation++
            requester.abandon()
            onLost("Audio focus request denied")
        }
        return granted
    }

    @Synchronized private fun changed(ticket: Long, signal: FocusSignal) {
        if (!started || ticket != generation) return
        hasFocus = signal == FocusSignal.GAIN
        if (hasFocus) onGranted() else onLost("Audio focus ${signal.name}")
    }
}
