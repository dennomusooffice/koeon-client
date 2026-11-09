package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.audio.InputGainProcessor
import com.dennomuso.koeon.core.ptt.PttSnapshot
import com.dennomuso.koeon.core.ptt.PttState

/** Gain measurement for the standard LiveKit path. */
internal fun InputGainProcessor.onLiveKitPttSnapshot(previous: PttState, snapshot: PttSnapshot) {
    fun PttState.isCapturing() = this == PttState.TRANSMITTING || this == PttState.RELEASING
    if (snapshot.state.isCapturing() && !previous.isCapturing()) {
        beginTransmission()
    } else if (!snapshot.state.isCapturing() && previous.isCapturing()) {
        // Safety stops and failed release paths also return to IDLE. They
        // must discard the measurement rather than train the next utterance.
        endTransmission(learn = snapshot.lastError == null &&
            snapshot.release.terminalRecoveryResult == "NORMAL_COMPLETE")
    }
}
