package com.dennomuso.koeon.service

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Test

class HeadsetPttPolicyTest {
    private val eligible = HeadsetPttEligibility(
        true, true, true, true, HeadsetPttMode.MOMENTARY,
    )

    @Test fun `initial join starts FGS while routine update only targets running service`() {
        assertEquals(
            ForegroundServiceDelivery.START_FOREGROUND,
            foregroundServiceDelivery(initialJoin = true, serviceRunning = false),
        )
        assertEquals(
            ForegroundServiceDelivery.UPDATE_RUNNING_SERVICE,
            foregroundServiceDelivery(initialJoin = false, serviceRunning = true),
        )
        assertEquals(
            ForegroundServiceDelivery.IGNORE,
            foregroundServiceDelivery(initialJoin = false, serviceRunning = false),
        )
    }

    @Test fun `headset DOWN UP uses hold semantics and ignores repeat DOWN`() {
        val policy = HeadsetPttPolicy()
        assertEquals(HeadsetPttAction.DOWN, evaluate(policy, KeyEvent.ACTION_DOWN))
        assertEquals(HeadsetPttAction.IGNORE, evaluate(policy, KeyEvent.ACTION_DOWN, repeat = 1))
        assertEquals(HeadsetPttAction.UP, evaluate(policy, KeyEvent.ACTION_UP))
    }

    @Test fun `toggle mode alternates DOWN and UP while ignoring physical UP`() {
        val policy = HeadsetPttPolicy()
        val toggle = eligible.copy(mode = HeadsetPttMode.TOGGLE)
        repeat(50) {
            assertEquals(HeadsetPttAction.DOWN, evaluate(policy, KeyEvent.ACTION_DOWN, eligibility = toggle))
            assertEquals(HeadsetPttAction.IGNORE, evaluate(policy, KeyEvent.ACTION_UP, eligibility = toggle))
            assertEquals(HeadsetPttAction.UP, evaluate(policy, KeyEvent.ACTION_DOWN, eligibility = toggle))
            assertEquals(HeadsetPttAction.IGNORE, evaluate(policy, KeyEvent.ACTION_UP, eligibility = toggle))
        }
    }

    @Test fun `toggle repeat DOWN is ignored and safety reset rearms first press`() {
        val policy = HeadsetPttPolicy()
        val toggle = eligible.copy(mode = HeadsetPttMode.TOGGLE)
        assertEquals(HeadsetPttAction.DOWN, evaluate(policy, KeyEvent.ACTION_DOWN, eligibility = toggle))
        assertEquals(HeadsetPttAction.IGNORE, evaluate(policy, KeyEvent.ACTION_DOWN, repeat = 1, eligibility = toggle))
        assertEquals(HeadsetPttAction.IGNORE, evaluate(policy, KeyEvent.ACTION_UP, eligibility = toggle))
        policy.forceRelease()
        assertEquals(HeadsetPttAction.DOWN, evaluate(policy, KeyEvent.ACTION_DOWN, eligibility = toggle))
    }

    @Test fun `disabled listener or interrupted audio ignores media controls`() {
        val policy = HeadsetPttPolicy()
        assertEquals(HeadsetPttAction.IGNORE, evaluate(policy, KeyEvent.ACTION_DOWN, eligibility = eligible.copy(settingEnabled = false)))
        assertEquals(HeadsetPttAction.IGNORE, evaluate(policy, KeyEvent.ACTION_DOWN, eligibility = eligible.copy(canPublish = false)))
        assertEquals(HeadsetPttAction.IGNORE, evaluate(policy, KeyEvent.ACTION_DOWN, eligibility = eligible.copy(audioReady = false)))
    }

    @Test fun `unsupported volume and track controls are not intercepted`() {
        val policy = HeadsetPttPolicy()
        assertEquals(HeadsetPttAction.IGNORE, evaluate(policy, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_VOLUME_UP))
        assertEquals(HeadsetPttAction.IGNORE, evaluate(policy, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_NEXT))
    }

    @Test fun `external input route loss stops only active TX`() {
        assertEquals(RouteLossPttAction.STOP_TX, routeLossPttAction(true, true))
        assertEquals(RouteLossPttAction.KEEP_RX, routeLossPttAction(true, false))
        assertEquals(RouteLossPttAction.KEEP_RX, routeLossPttAction(false, true))
    }

    private fun evaluate(
        policy: HeadsetPttPolicy,
        action: Int,
        code: Int = KeyEvent.KEYCODE_HEADSETHOOK,
        repeat: Int = 0,
        eligibility: HeadsetPttEligibility = eligible,
    ) = policy.evaluate(code, action, repeat, eligibility)
}
