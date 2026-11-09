package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.ptt.RxState
import java.time.Instant
import org.junit.Assert.*
import org.junit.Test

class RemoteSpeakerTest {
    private val now = Instant.parse("2026-11-09T00:00:00Z")
    @Test fun `ended RX cannot resurrect stale SDK speaker`() {
        assertNull(remoteSpeaker(null, null, "old", RxState.RX_IDLE, now))
    }
    @Test fun `valid silent Floor remains busy until expiry even when SDK is silent`() {
        assertEquals("owner", remoteSpeaker("owner", now.plusSeconds(3), null, RxState.RX_IDLE, now))
        assertNull(remoteSpeaker("owner", now.plusSeconds(3), "old", RxState.RX_IDLE, now.plusSeconds(3)))
    }
    @Test fun `unknown or expired Floor does not indefinitely block after poll failure`() {
        assertNull(remoteSpeaker("old", null, null, RxState.RX_IDLE, now))
        assertNull(remoteSpeaker("old", now.minusSeconds(1), "old", RxState.RX_IDLE, now))
    }
    @Test fun `active RX may provide speaker independently of Floor poll`() {
        assertEquals("new", remoteSpeaker("old", now.minusSeconds(1), "new", RxState.RX_ACTIVE, now))
        assertNull(remoteSpeaker(null, null, null, RxState.RX_ACTIVE, now))
    }
}
