package com.dennomuso.koeon.core.audio

import android.media.AudioAttributes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TonePttCuePlayerTest {
    @Test
    fun `cue uses voice communication signalling semantics`() {
        assertEquals(AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING, PTT_CUE_AUDIO_USAGE)
    }

    @Test
    fun `status cues are rate limited independently`() {
        var now = 1_000L
        val limiter = StatusCueRateLimiter({ now })
        assertTrue(limiter.accept("busy"))
        assertFalse(limiter.accept("busy"))
        assertTrue(limiter.accept("error"))
        now += 500
        assertTrue(limiter.accept("busy"))
    }

    @Test
    fun `FIELD LOUD profiles are distinct and never clip digitally`() {
        assertEquals(1_350.0, TonePttCuePlayer.TX_START_FREQUENCY_HZ, 0.0)
        assertEquals(850.0, TonePttCuePlayer.TX_END_FREQUENCY_HZ, 0.0)
        assertEquals(1_100.0, TonePttCuePlayer.RX_START_FREQUENCY_HZ, 0.0)
        assertEquals(700.0, TonePttCuePlayer.RX_END_FREQUENCY_HZ, 0.0)
        assertTrue(TonePttCuePlayer.TX_RX_VOLUME in 0f..1f)
        assertTrue(TonePttCuePlayer.BUSY_VOLUME > TonePttCuePlayer.TX_RX_VOLUME)
        assertTrue(TonePttCuePlayer.ERROR_VOLUME > TonePttCuePlayer.BUSY_VOLUME)
        assertTrue(TonePttCuePlayer.ERROR_VOLUME <= 1f)
        val samples = TonePttCuePlayer().makeCue(TonePttCuePlayer.TX_START_FREQUENCY_HZ, 100)
        assertTrue(samples.all { it.toInt() in Short.MIN_VALUE..Short.MAX_VALUE })
    }
}
