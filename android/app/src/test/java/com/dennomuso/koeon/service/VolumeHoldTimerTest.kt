package com.dennomuso.koeon.service

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class VolumeHoldTimerTest {
    @Test fun heldKeyFiresWithoutRepeatOrReleaseAndReleaseDoesNotRetrigger() = runTest {
        val gate = BackgroundVolumeKeyGate()
        val timer = VolumeHoldTimer(this) { testScheduler.currentTime }
        var count = 0
        gate.event(24, true, 0, false, 0, 0, true)
        timer.start(24, 0) {
            if (gate.event(24, true, 1, false, 0, testScheduler.currentTime, true) == BackgroundVolumeDecision.TOGGLE) count++
        }
        advanceTimeBy(599); runCurrent(); assertEquals(0, count)
        advanceTimeBy(1); runCurrent(); assertEquals(1, count)
        advanceTimeBy(2000); runCurrent(); assertEquals(1, count)
        assertEquals(BackgroundVolumeDecision.CONSUME, gate.event(24, false, 0, false, 0, 2600, true))
    }
    @Test fun releaseAndSettingsCancellationPreventPendingTimers() = runTest {
        val timer = VolumeHoldTimer(this) { testScheduler.currentTime }
        var count = 0
        timer.start(24, 0) { count++ }
        advanceTimeBy(200); timer.release(24)
        timer.start(25, 200) { count++ }
        advanceTimeBy(100); timer.clear()
        advanceTimeBy(1000); runCurrent(); assertEquals(0, count)
    }
    @Test fun osRepeatBeforeTimerCannotDoubleToggle() = runTest {
        val gate = BackgroundVolumeKeyGate()
        val timer = VolumeHoldTimer(this) { testScheduler.currentTime }
        var count = 0
        gate.event(24, true, 0, false, 0, 0, true)
        timer.start(24, 0) {
            if (gate.event(24, true, 1, false, 0, testScheduler.currentTime, true) == BackgroundVolumeDecision.TOGGLE) count++
        }
        advanceTimeBy(600)
        if (gate.event(24, true, 1, false, 0, 600, true) == BackgroundVolumeDecision.TOGGLE) count++
        runCurrent(); assertEquals(1, count)
    }
}
