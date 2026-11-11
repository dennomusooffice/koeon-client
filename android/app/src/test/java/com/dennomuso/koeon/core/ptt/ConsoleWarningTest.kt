package com.dennomuso.koeon.core.ptt

import com.dennomuso.koeon.core.audio.AudioAvailabilityState
import org.junit.Assert.*
import org.junit.Test

class ConsoleWarningTest {
    @Test fun `recovered state clears warning without clearing diagnostic history`() {
        assertTrue(consoleWarningActive(PttSemanticState.ERROR, AudioAvailabilityState.READY))
        for (state in listOf(PttSemanticState.READY, PttSemanticState.BUSY_REMOTE, PttSemanticState.TALKING)) {
            assertFalse(consoleWarningActive(state, AudioAvailabilityState.READY))
            assertTrue(consoleWarningActive(state, AudioAvailabilityState.INTERRUPTED))
            assertTrue(consoleWarningActive(state, AudioAvailabilityState.RECOVERY_FAILED))
        }
        assertFalse(consoleWarningActive(PttSemanticState.RECOVERING, AudioAvailabilityState.RECOVERING))
    }
}
