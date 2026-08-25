package com.dennomuso.koeon.core.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioInterruptionStateTest {
    @Test
    fun `duplicate interruption is idempotent and stale recovery is ignored`() {
        var now = 100L
        val machine = AudioInterruptionStateMachine { now }
        val first = machine.interrupt("focus lost")
        assertEquals(first, machine.interrupt("duplicate"))
        assertEquals("focus lost", machine.snapshot.interruptionReason)

        assertTrue(machine.beginRecovery(first))
        now = 200L
        val newer = machine.interrupt("new focus loss")
        assertFalse(machine.completeRecovery(first))
        assertTrue(newer > first)
        assertEquals(AudioAvailabilityState.INTERRUPTED, machine.snapshot.state)
    }

    @Test
    fun `focus regain recovery reaches ready without resuming transmission`() {
        var now = 1_000L
        val machine = AudioInterruptionStateMachine { now }
        val generation = machine.interrupt("focus lost transient")
        now = 1_100L
        assertTrue(machine.beginRecovery(generation))
        now = 1_300L
        assertTrue(machine.completeRecovery(generation))
        assertEquals(AudioAvailabilityState.READY, machine.snapshot.state)
        assertEquals(200L, machine.snapshot.recoveryMs)
        assertEquals("success", machine.snapshot.autoRecoveryResult)
    }

    @Test
    fun `recovery failure is explicit and retryable`() {
        val machine = AudioInterruptionStateMachine { 1L }
        val generation = machine.interrupt("focus lost")
        assertTrue(machine.beginRecovery(generation))
        assertTrue(machine.failRecovery(generation, "route unavailable"))
        assertEquals(AudioAvailabilityState.RECOVERY_FAILED, machine.snapshot.state)
        assertEquals("route unavailable", machine.snapshot.lastRecoveryError)
        assertTrue(machine.beginRecovery(generation))
    }
}
