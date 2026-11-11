package com.dennomuso.koeon.service

import org.junit.Assert.assertEquals
import org.junit.Test

class BackgroundVolumeKeyGateTest {
    private fun BackgroundVolumeKeyGate.down(key: Int = 24, at: Long = 100, now: Long = at,
        repeat: Int = 0, eligible: Boolean = true) = event(key, true, repeat, false, at, now, eligible)
    private fun BackgroundVolumeKeyGate.up(key: Int = 24, at: Long = 100, now: Long = 200,
        cancelled: Boolean = false, eligible: Boolean = true) = event(key, false, 0, cancelled, at, now, eligible)

    @Test fun shortPressOnlyAdjustsVolumeAndDuplicateUpPasses() {
        val gate = BackgroundVolumeKeyGate()
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.down())
        assertEquals(BackgroundVolumeDecision.SHORT_PRESS, gate.up(now = 699))
        assertEquals(BackgroundVolumeDecision.PASS, gate.up())
    }
    @Test fun longRepeatTogglesOnceAtBoundaryAndNeverAgainUntilRelease() {
        val gate = BackgroundVolumeKeyGate()
        gate.down()
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.down(now = 699, repeat = 1))
        assertEquals(BackgroundVolumeDecision.TOGGLE, gate.down(now = 700, repeat = 2))
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.down(now = 2000, repeat = 20))
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(now = 2500))
        gate.down(at = 3000)
        assertEquals(BackgroundVolumeDecision.TOGGLE, gate.up(at = 3000, now = 3600))
    }
    @Test fun cancelOrphanAndInvalidTimeNeverToggle() {
        val gate = BackgroundVolumeKeyGate()
        assertEquals(BackgroundVolumeDecision.PASS, gate.up(now = 2000))
        gate.down(); assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(now = 2000, cancelled = true))
        gate.down(); assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(now = 99))
        assertEquals(BackgroundVolumeDecision.PASS, gate.down(repeat = 1))
    }
    @Test fun simultaneousKeysAndStaleReleaseNeverToggle() {
        val gate = BackgroundVolumeKeyGate()
        gate.down(24); gate.down(25)
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(24, now = 1000))
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(25, now = 1000))
        gate.down(at = 300)
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(at = 100, now = 1000))
    }
    @Test fun settingCycleAndEligibilityLossInvalidatePendingHold() {
        val gate = BackgroundVolumeKeyGate()
        gate.down(); gate.invalidate()
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.down(now = 1000, repeat = 1))
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(now = 1000))
        assertEquals(BackgroundVolumeDecision.PASS, gate.down(eligible = false))
        assertEquals(BackgroundVolumeDecision.PASS, gate.up())
        gate.down(); assertEquals(BackgroundVolumeDecision.CONSUME, gate.up(now = 1000, eligible = false))
    }
    @Test fun unrelatedKeysNeverConsumed() {
        val gate = BackgroundVolumeKeyGate()
        assertEquals(BackgroundVolumeDecision.PASS, gate.down(3))
        assertEquals(BackgroundVolumeDecision.PASS, gate.up(3))
    }
}
