package com.dennomuso.koeon.core.ptt

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

class PttInputSourceTest {
    @Test fun `app touch remains momentary for fifty cycles`() {
        val gate = AppTouchPttGate()
        repeat(50) {
            assertTrue(gate.down())
            assertFalse(gate.down())
            assertTrue(gate.up())
            assertFalse(gate.up())
            assertFalse(gate.isPressed())
        }
    }

    @Test fun `cancel releases exactly once`() {
        val gate = AppTouchPttGate()
        assertTrue(gate.down())
        assertTrue(gate.cancel())
        assertFalse(gate.cancel())
    }

    @Test fun `accepted touch survives preparing talking and self speaker states until physical up`() {
        val gate = AppTouchPttGate()
        assertTrue(gate.down())

        // These Product state transitions must not own or cancel the gesture lifetime.
        listOf("PREPARING", "TALKING", "CURRENT_SPEAKER_SELF").forEach { _ ->
            assertTrue(gate.isPressed())
        }

        assertTrue(gate.up())
        assertFalse(gate.up())
        assertFalse(gate.isPressed())
    }

    @Test fun `remote busy rejects a new touch without creating a gesture`() {
        val gate = AppTouchPttGate()
        val remoteBusyEligible = false

        assertFalse(remoteBusyEligible && gate.down())
        assertFalse(gate.isPressed())
        assertFalse(gate.up())
    }

    @Test fun `connection audio and route safety cancel an accepted touch exactly once`() {
        listOf("disconnect", "audio_interruption", "route_loss").forEach { _ ->
            val gate = AppTouchPttGate()
            assertTrue(gate.down())
            assertTrue(gate.cancel())
            assertFalse(gate.cancel())
            assertFalse(gate.up())
        }
    }

    @Test fun `hardware volume short presses toggle for fifty cycles`() {
        val gate = HardwareVolumePttGate()
        repeat(50) {
            assertTrue(gate.keyDown(0) == HardwareVolumeAction.IGNORE)
            assertTrue(gate.keyUp(false) == HardwareVolumeAction.DOWN)
            assertTrue(gate.keyDown(0) == HardwareVolumeAction.IGNORE)
            assertTrue(gate.keyUp(false) == HardwareVolumeAction.UP)
        }
        assertFalse(gate.isLatched())
    }

    @Test fun `hardware volume repeat and long press never toggle`() {
        val gate = HardwareVolumePttGate()
        gate.keyDown(0)
        gate.keyDown(1)
        assertTrue(gate.keyUp(false) == HardwareVolumeAction.IGNORE)
        gate.keyDown(0)
        assertTrue(gate.keyUp(true) == HardwareVolumeAction.IGNORE)
        assertFalse(gate.isLatched())
    }

    @Test fun `hardware volume ownership requires explicit foreground eligibility`() {
        assertFalse(HardwareVolumePttEligibility(HardwareVolumePttMode.OFF, true, true, true, true).consumesVolumeKeys())
        assertFalse(HardwareVolumePttEligibility(HardwareVolumePttMode.TOGGLE, true, true, true, false).consumesVolumeKeys())
        assertTrue(HardwareVolumePttEligibility(HardwareVolumePttMode.TOGGLE, true, true, true, true).consumesVolumeKeys())
    }

    @Test fun `hardware volume latch is independent and safety clear releases it`() {
        val app = AppTouchPttGate()
        val hardware = HardwareVolumePttGate()
        assertTrue(app.down())
        hardware.keyDown(0)
        assertEquals(HardwareVolumeAction.DOWN, hardware.keyUp(false))
        assertTrue(app.isPressed())
        assertTrue(hardware.clear())
        assertFalse(hardware.isLatched())
        assertTrue(app.isPressed())
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun `rapid up then down is serialized through release before rearm`() = runTest {
        val events = mutableListOf<String>()
        val queue = OrderedPttInputQueue(backgroundScope) { command ->
            when (command) {
                OrderedPttInputCommand.Up -> {
                    events += "up-start"
                    delay(100)
                    events += "up-complete"
                }
                is OrderedPttInputCommand.Down -> events += "down-${command.canTransmit}"
            }
        }

        queue.up()
        queue.down(canTransmit = true)
        runCurrent()
        advanceTimeBy(100)
        runCurrent()

        assertEquals(listOf("up-start", "up-complete", "down-true"), events)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun `up can cancel an in flight down without waiting for it to finish`() = runTest {
        val events = mutableListOf<String>()
        val queue = OrderedPttInputQueue(backgroundScope) { command ->
            when (command) {
                is OrderedPttInputCommand.Down -> {
                    events += "down-start"
                    delay(1_000)
                    events += "down-complete"
                }
                OrderedPttInputCommand.Up -> events += "up"
            }
        }

        queue.down(canTransmit = true)
        queue.up()
        runCurrent()

        assertEquals(listOf("down-start", "up"), events)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(listOf("down-start", "up", "down-complete"), events)
    }
}
