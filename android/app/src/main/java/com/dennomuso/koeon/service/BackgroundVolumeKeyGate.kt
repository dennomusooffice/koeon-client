package com.dennomuso.koeon.service

enum class BackgroundVolumeDecision { PASS, CONSUME, TOGGLE }

/** At most two volume sequences; a completed, uncancelled short press is required. */
class BackgroundVolumeKeyGate {
    private data class Press(val downAt: Long, val generation: Long, var invalid: Boolean)
    private val presses = mutableMapOf<Int, Press>()
    private var generation = 0L

    fun invalidate() { generation++ }

    fun event(key: Int, down: Boolean, repeat: Int, cancelled: Boolean,
              downAt: Long, now: Long, eligible: Boolean): BackgroundVolumeDecision {
        if (key != 24 && key != 25) return BackgroundVolumeDecision.PASS
        val previous = presses[key]
        if (down) {
            if (previous != null && previous.downAt == downAt) {
                previous.invalid = true
                return BackgroundVolumeDecision.CONSUME
            }
            presses.remove(key)
            if (!eligible || repeat != 0 || cancelled) return BackgroundVolumeDecision.PASS
            val overlap = presses.isNotEmpty()
            if (overlap) presses.values.forEach { it.invalid = true }
            presses[key] = Press(downAt, generation, overlap)
            return BackgroundVolumeDecision.CONSUME
        }
        if (previous == null) return BackgroundVolumeDecision.PASS
        presses.remove(key)
        val valid = eligible && !cancelled && repeat == 0 && !previous.invalid &&
            previous.generation == generation && previous.downAt == downAt && now - downAt in 0..499
        return if (valid) BackgroundVolumeDecision.TOGGLE else BackgroundVolumeDecision.CONSUME
    }
}
