package com.dennomuso.koeon.core.ptt

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PttSemanticStateTest {
    @Test fun `remote busy returns to ready after receive ends`() {
        assertEquals(PttSemanticState.BUSY_REMOTE, pttSemanticState(true, true, false, true, PttState.IDLE))
        assertEquals(PttSemanticState.READY, pttSemanticState(true, true, false, false, PttState.IDLE))
    }

    @Test fun `listener never appears ready and priority is stable`() {
        assertEquals(PttSemanticState.RX_ONLY, pttSemanticState(false, true, false, false, PttState.IDLE))
        assertEquals(PttSemanticState.ERROR, pttSemanticState(true, true, false, true, PttState.ERROR))
        assertEquals(PttSemanticState.RECOVERING, pttSemanticState(true, true, true, true, PttState.IDLE))
        assertEquals(PttSemanticState.OFFLINE, pttSemanticState(true, false, false, false, PttState.IDLE))
        assertEquals(PttSemanticState.TALKING, pttSemanticState(true, true, false, false, PttState.TRANSMITTING))
        assertEquals(PttSemanticState.PREPARING, pttSemanticState(true, true, false, false, PttState.REQUESTING_FLOOR))
        assertEquals(PttSemanticState.PREPARING, pttSemanticState(true, true, false, false, PttState.RELEASING))
        assertEquals(PttSemanticState.BUSY_REMOTE, pttSemanticState(true, true, false, false, PttState.BUSY))
    }

    @Test fun `remote speaker blocks touch headset and hardware eligibility`() {
        assertFalse(localPttEligible(true, true, true, true, remoteTalking = true))
        assertTrue(localPttEligible(true, true, true, true, remoteTalking = false))
    }
}
