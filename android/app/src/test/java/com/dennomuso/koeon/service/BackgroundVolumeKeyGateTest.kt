package com.dennomuso.koeon.service

import org.junit.Assert.assertEquals
import org.junit.Test

class BackgroundVolumeKeyGateTest {
    private fun BackgroundVolumeKeyGate.down(key: Int = 24, at: Long = 100, repeat: Int = 0, eligible: Boolean = true) =
        event(key, true, repeat, false, at, at, eligible)
    private fun BackgroundVolumeKeyGate.up(key: Int = 24, at: Long = 100, now: Long = 200, cancelled: Boolean = false, eligible: Boolean = true) =
        event(key, false, 0, cancelled, at, now, eligible)

    @Test fun shortPairTogglesOnlyOnce() {
        val gate = BackgroundVolumeKeyGate()
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.down())
        assertEquals(BackgroundVolumeDecision.TOGGLE, gate.up())
        assertEquals(BackgroundVolumeDecision.PASS, gate.up())
    }
    @Test fun repeatLongCancelAndOrphanNeverToggle() {
        val gate = BackgroundVolumeKeyGate()
        assertEquals(BackgroundVolumeDecision.PASS, gate.up())
        gate.down(); gate.down(repeat = 1)
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.up())
        gate.down(); assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(now = 600))
        gate.down(); assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(cancelled = true))
    }
    @Test fun simultaneousKeysAndStaleReleaseNeverToggle() {
        val gate = BackgroundVolumeKeyGate()
        gate.down(24); gate.down(25)
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(24))
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(25))
        gate.down(at = 300)
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(at = 100))
    }
    @Test fun settingCycleInvalidatesPendingPairButConsumesItsRelease() {
        val gate = BackgroundVolumeKeyGate()
        gate.down(); gate.invalidate()
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.up())
        assertEquals(BackgroundVolumeDecision.PASS, gate.down(eligible = false))
        assertEquals(BackgroundVolumeDecision.PASS, gate.up())
        gate.down(); assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(eligible = false))
    }
    @Test fun unrelatedKeysNeverConsumed() {
        val gate = BackgroundVolumeKeyGate()
        assertEquals(BackgroundVolumeDecision.PASS, gate.down(3))
        assertEquals(BackgroundVolumeDecision.PASS, gate.up(3))
    }
}
