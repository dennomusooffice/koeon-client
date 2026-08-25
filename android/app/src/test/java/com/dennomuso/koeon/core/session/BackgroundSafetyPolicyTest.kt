package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.ptt.PttState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundSafetyPolicyTest {
    @Test fun `network or focus loss stops only an active floor operation`() {
        assertTrue(shouldStopPttForSafety(PttState.REQUESTING_FLOOR))
        assertTrue(shouldStopPttForSafety(PttState.TRANSMITTING))
        assertFalse(shouldStopPttForSafety(PttState.IDLE))
        assertFalse(shouldStopPttForSafety(PttState.RX_ONLY))
        assertFalse(shouldStopPttForSafety(PttState.BUSY))
        assertFalse(shouldStopPttForSafety(PttState.ERROR))
    }
}
