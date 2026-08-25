package com.dennomuso.koeon.core.haptics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PttHapticFeedbackControllerTest {
    @Test
    fun `DOWN haptic occurs before caller starts Floor acquire`() {
        val events = mutableListOf<String>()
        val controller = PttHapticFeedbackController(FakePerformer(onPress = { events += "haptic" }))

        assertTrue(controller.press(eligible = true))
        events += "floor"

        assertEquals(listOf("haptic", "floor"), events)
    }

    @Test
    fun `BUSY operation gets one press and duplicate DOWN is suppressed`() {
        val performer = FakePerformer()
        val controller = PttHapticFeedbackController(performer)

        assertTrue(controller.press(eligible = true))
        assertFalse(controller.press(eligible = true))

        assertEquals(1, performer.pressCount)
        assertEquals(HapticResult.SKIPPED_DUPLICATE, controller.current().lastResult)
    }

    @Test
    fun `UP gets one release haptic and publishes released visual state`() {
        val snapshots = mutableListOf<HapticSnapshot>()
        val performer = FakePerformer()
        val controller = PttHapticFeedbackController(performer, { 123L }, snapshots::add)

        controller.press(eligible = true)
        assertTrue(controller.release())
        assertFalse(controller.release())

        assertEquals(1, performer.releaseCount)
        assertEquals(listOf(true, false, false), snapshots.map { it.inputPressed })
    }

    @Test
    fun `Listener input emits no haptic`() {
        val performer = FakePerformer()
        val controller = PttHapticFeedbackController(performer)

        assertFalse(controller.press(eligible = false))
        assertEquals(0, performer.pressCount)
        assertFalse(controller.current().inputPressed)
    }

    @Test
    fun `unsupported disabled and failed feedback never reject eligible PTT input`() {
        val unsupported = PttHapticFeedbackController(FakePerformer(supported = false))
        val disabled = PttHapticFeedbackController(FakePerformer(enabled = false))
        val failed = PttHapticFeedbackController(FakePerformer(fail = true))

        assertTrue(unsupported.press(eligible = true))
        assertEquals(HapticResult.UNSUPPORTED, unsupported.current().lastResult)
        assertTrue(disabled.press(eligible = true))
        assertEquals(HapticResult.DISABLED, disabled.current().lastResult)
        assertTrue(failed.press(eligible = true))
        assertEquals(HapticResult.FAILED, failed.current().lastResult)
    }

    private class FakePerformer(
        override val supported: Boolean = true,
        override val enabled: Boolean = true,
        private val fail: Boolean = false,
        private val onPress: () -> Unit = {},
    ) : HapticPerformer {
        var pressCount = 0
        var releaseCount = 0

        override fun prepare() = Unit

        override fun performPress(): Boolean {
            pressCount += 1
            onPress()
            if (fail) error("haptic unavailable")
            return true
        }

        override fun performRelease(): Boolean {
            releaseCount += 1
            if (fail) error("haptic unavailable")
            return true
        }
    }
}
