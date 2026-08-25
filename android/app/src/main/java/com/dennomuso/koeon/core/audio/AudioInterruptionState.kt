package com.dennomuso.koeon.core.audio

enum class AudioAvailabilityState {
    READY,
    INTERRUPTED,
    RECOVERING,
    RECOVERY_FAILED,
}

data class AudioInterruptionSnapshot(
    val state: AudioAvailabilityState = AudioAvailabilityState.READY,
    val interruptionStartedAtMs: Long? = null,
    val interruptionEndedAtMs: Long? = null,
    val interruptionReason: String? = null,
    val recoveryStartedAtMs: Long? = null,
    val recoveryCompletedAtMs: Long? = null,
    val recoveryMs: Long? = null,
    val autoRecoveryResult: String = "not_required",
    val lastRecoveryError: String? = null,
    val generation: Long = 0,
)

class AudioInterruptionStateMachine(private val nowMs: () -> Long) {
    var snapshot = AudioInterruptionSnapshot()
        private set

    fun interrupt(reason: String): Long {
        if (snapshot.state == AudioAvailabilityState.INTERRUPTED) return snapshot.generation
        snapshot = snapshot.copy(
            state = AudioAvailabilityState.INTERRUPTED,
            interruptionStartedAtMs = nowMs(),
            interruptionEndedAtMs = null,
            interruptionReason = reason,
            recoveryStartedAtMs = null,
            recoveryCompletedAtMs = null,
            recoveryMs = null,
            autoRecoveryResult = "pending",
            lastRecoveryError = null,
            generation = snapshot.generation + 1,
        )
        return snapshot.generation
    }

    fun beginRecovery(generation: Long): Boolean {
        if (generation != snapshot.generation || snapshot.state == AudioAvailabilityState.READY ||
            snapshot.state == AudioAvailabilityState.RECOVERING
        ) return false
        val now = nowMs()
        snapshot = snapshot.copy(
            state = AudioAvailabilityState.RECOVERING,
            interruptionEndedAtMs = now,
            recoveryStartedAtMs = now,
            autoRecoveryResult = "in_progress",
            lastRecoveryError = null,
        )
        return true
    }

    fun completeRecovery(generation: Long): Boolean {
        if (generation != snapshot.generation || snapshot.state != AudioAvailabilityState.RECOVERING) return false
        val completedAt = nowMs()
        snapshot = snapshot.copy(
            state = AudioAvailabilityState.READY,
            recoveryCompletedAtMs = completedAt,
            recoveryMs = (completedAt - (snapshot.recoveryStartedAtMs ?: completedAt)).coerceAtLeast(0L),
            autoRecoveryResult = "success",
            lastRecoveryError = null,
        )
        return true
    }

    fun failRecovery(generation: Long, error: String): Boolean {
        if (generation != snapshot.generation || snapshot.state != AudioAvailabilityState.RECOVERING) return false
        snapshot = snapshot.copy(
            state = AudioAvailabilityState.RECOVERY_FAILED,
            autoRecoveryResult = "failed",
            lastRecoveryError = error,
        )
        return true
    }

    fun reset() {
        snapshot = AudioInterruptionSnapshot()
    }
}
