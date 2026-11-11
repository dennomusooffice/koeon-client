package com.dennomuso.koeon.service

enum class BackgroundVolumeDecision { PASS, CONSUME, SHORT_PRESS, TOGGLE }

/** Two bounded key sequences. A long press toggles once; short release adjusts volume. */
class BackgroundVolumeKeyGate {
    companion object { const val LONG_PRESS_MS = 600L }
    private data class Press(val downAt: Long, val generation: Long,
                             var invalid: Boolean, var fired: Boolean = false)
    private val presses = mutableMapOf<Int, Press>()
    private var generation = 0L

    fun invalidate() { generation++ }

    fun event(key: Int, down: Boolean, repeat: Int, cancelled: Boolean,
              downAt: Long, now: Long, eligible: Boolean): BackgroundVolumeDecision {
        if (key != 24 && key != 25) return BackgroundVolumeDecision.PASS
        val previous = presses[key]
        if (down && previous == null) {
            if (!eligible || repeat != 0 || cancelled || now < downAt) return BackgroundVolumeDecision.PASS
            val overlap = presses.isNotEmpty()
            if (overlap) presses.values.forEach { it.invalid = true }
            presses[key] = Press(downAt, generation, overlap)
            return BackgroundVolumeDecision.CONSUME
        }
        if (previous == null) return BackgroundVolumeDecision.PASS
        if (!down) presses.remove(key)
        if (!eligible || cancelled || previous.generation != generation ||
            previous.downAt != downAt || now < downAt) previous.invalid = true
        if (previous.invalid || previous.fired) return BackgroundVolumeDecision.CONSUME
        if (now - downAt >= LONG_PRESS_MS) {
            previous.fired = true
            return BackgroundVolumeDecision.TOGGLE
        }
        return if (down) BackgroundVolumeDecision.CONSUME else BackgroundVolumeDecision.SHORT_PRESS
    }
}
