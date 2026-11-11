package com.dennomuso.koeon.core.ptt

import com.dennomuso.koeon.core.audio.AudioAvailabilityState

enum class PttSemanticState {
    READY, INTERRUPTED, TALKING, BUSY_REMOTE, PREPARING, ERROR, RECOVERING, OFFLINE, RX_ONLY
}

fun localPttEligible(
    operationallyActive: Boolean,
    canPublish: Boolean,
    connected: Boolean,
    audioReady: Boolean,
    remoteTalking: Boolean,
): Boolean = operationallyActive && canPublish && connected && audioReady && !remoteTalking

fun pttSemanticState(
    canPublish: Boolean,
    connected: Boolean,
    recovering: Boolean,
    remoteTalking: Boolean,
    pttState: PttState,
    audioAvailability: AudioAvailabilityState = AudioAvailabilityState.READY,
): PttSemanticState = when {
    !canPublish -> PttSemanticState.RX_ONLY
    pttState == PttState.ERROR -> PttSemanticState.ERROR
    !connected -> PttSemanticState.OFFLINE
    recovering || audioAvailability == AudioAvailabilityState.RECOVERING -> PttSemanticState.RECOVERING
    audioAvailability == AudioAvailabilityState.INTERRUPTED -> PttSemanticState.INTERRUPTED
    audioAvailability == AudioAvailabilityState.RECOVERY_FAILED -> PttSemanticState.ERROR
    pttState == PttState.TRANSMITTING -> PttSemanticState.TALKING
    pttState == PttState.REQUESTING_FLOOR || pttState == PttState.RELEASING -> PttSemanticState.PREPARING
    remoteTalking || pttState == PttState.BUSY -> PttSemanticState.BUSY_REMOTE
    else -> PttSemanticState.READY
}

/** Current warning only. Historical error text must never latch the console ring red. */
fun consoleWarningActive(state: PttSemanticState, audio: AudioAvailabilityState): Boolean =
    state in setOf(PttSemanticState.ERROR, PttSemanticState.INTERRUPTED) ||
        audio in setOf(AudioAvailabilityState.INTERRUPTED, AudioAvailabilityState.RECOVERY_FAILED)
