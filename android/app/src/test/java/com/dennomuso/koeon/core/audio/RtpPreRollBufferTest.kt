package com.dennomuso.koeon.core.audio

import org.junit.Assert.*
import org.junit.Test

class RtpPreRollBufferTest {
    private fun frame(value: Int) = ByteArray(960) { value.toByte() }
    private fun RtpPreRollBuffer.tick(value: Int) = process(frame(value), 48000, 1, 2)

    @Test fun preservesPreRollAndLiveOrderThroughRelease() {
        val queue = RtpPreRollBuffer()
        queue.arm()
        assertArrayEquals(frame(0), queue.tick(99))
        assertTrue(queue.markCueBoundary())
        for (n in 1..4) assertArrayEquals(frame(0), queue.tick(n))
        assertTrue(queue.authorize())
        for (n in 5..8) assertArrayEquals(frame(n - 4), queue.tick(n))
        queue.freeze()
        for (n in 5..8) assertArrayEquals(frame(n), queue.tick(99))
        assertTrue(queue.isDrained())
        assertArrayEquals(frame(0), queue.tick(99))
    }

    @Test fun shortReleaseWhileWaitingForReadinessKeepsOnlyCapturedSpeech() {
        val queue = RtpPreRollBuffer()
        queue.arm(); queue.tick(99); queue.markCueBoundary()
        queue.tick(1); queue.tick(2); queue.freeze()
        assertArrayEquals(frame(0), queue.tick(99))
        assertTrue(queue.authorize())
        assertArrayEquals(frame(1), queue.tick(99))
        assertArrayEquals(frame(2), queue.tick(99))
        assertTrue(queue.isDrained())
    }

    @Test fun capacityFailureDoesNotDiscardHeadAndPretendSuccess() {
        val queue = RtpPreRollBuffer(maximumMilliseconds = 20)
        queue.arm(); queue.tick(1); queue.tick(2)
        assertArrayEquals(frame(0), queue.tick(3))
        assertEquals("RTP_PREROLL_CAPACITY_EXCEEDED", queue.failure)
        assertFalse(queue.authorize())
    }

    @Test fun routeChangeFailsClosedAndResetCannotReplayPreviousUtterance() {
        val queue = RtpPreRollBuffer()
        queue.arm(); queue.tick(1); queue.authorize()
        assertArrayEquals(ByteArray(320), queue.process(ByteArray(320) { 2 }, 16000, 1, 2))
        assertEquals("RTP_CAPTURE_FORMAT_CHANGED", queue.failure)
        queue.clear()
        assertArrayEquals(frame(0), queue.tick(3))
        queue.arm(); queue.tick(4); queue.markCueBoundary(); queue.authorize()
        assertArrayEquals(frame(5), queue.tick(5))
    }
}
