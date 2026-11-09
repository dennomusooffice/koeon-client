package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.ptt.RxState
import java.time.Instant

/** UI/eligibility hint only. Transmission still requires a server Floor grant. */
internal fun remoteSpeaker(
    floorSpeaker: String?,
    floorExpiresAt: Instant?,
    liveKitSpeaker: String?,
    rxState: RxState,
    now: Instant,
): String? = when {
    floorSpeaker != null && floorExpiresAt != null && now.isBefore(floorExpiresAt) -> floorSpeaker
    rxState != RxState.RX_IDLE -> liveKitSpeaker
    else -> null
}
