package com.dennomuso.koeon.core.audio

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

class BufferedAudioTimelineTest {
    @Test fun `canonical PCM frames are 20ms and ordered from seq0`() {
        val capture = Batv1CaptureBuffer()
        capture.arm("generation")
        val source = ByteArray(BATV1_BYTES_PER_FRAME * 2) { (it % 127).toByte() }
        capture.appendPostProcessedPcm(ByteBuffer.wrap(source))
        val frames = capture.snapshotFrames()
        assertEquals(2, frames.size)
        assertArrayEquals(source.copyOfRange(0, BATV1_BYTES_PER_FRAME), frames[0])
        assertArrayEquals(source.copyOfRange(BATV1_BYTES_PER_FRAME, source.size), frames[1])
    }

    @Test fun `prewarmed local track sink PCM confirms capture without publication`() {
        val capture = Batv1CaptureBuffer()
        capture.arm("generation")
        val tenMilliseconds = ByteArray(BATV1_BYTES_PER_FRAME / 2) { 7 }
        assertTrue(capture.appendLiveKitPcm(ByteBuffer.wrap(tenMilliseconds), 16, 48_000, 1, 480))
        assertTrue(capture.appendLiveKitPcm(ByteBuffer.wrap(tenMilliseconds), 16, 48_000, 1, 480))
        assertEquals(1, capture.frameCount())
        assertEquals(null, capture.lastErrorCode())
    }

    @Test fun `unsupported sink format never fabricates canonical PCM`() {
        val capture = Batv1CaptureBuffer()
        capture.arm("generation")
        assertEquals(false, capture.appendLiveKitPcm(ByteBuffer.wrap(ByteArray(960)), 16, 44_100, 1, 441))
        assertEquals(0, capture.frameCount())
        assertEquals("BATV1_CAPTURE_FORMAT_UNSUPPORTED", capture.lastErrorCode())
    }

    @Test fun `cue boundary drops earlier frames and next frame becomes seq0`() {
        val capture = Batv1CaptureBuffer()
        capture.arm("generation")
        capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME) { 1 }))
        capture.markCueBoundary()
        capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME) { 2 }))
        assertEquals(1, capture.snapshotFrames().size)
        assertArrayEquals(ByteArray(BATV1_BYTES_PER_FRAME) { 2 }, capture.snapshotFrames().single())
    }

    @Test fun `sender RAM is bounded to exactly 6000ms`() {
        val capture = Batv1CaptureBuffer()
        capture.arm("generation")
        repeat(BATV1_MAX_FRAMES + 25) {
            capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME) { it.toByte() }))
        }
        assertEquals(300, capture.frameCount())
        assertEquals(25, capture.droppedFrames())
        assertEquals(6_000, capture.frameCount() * BATV1_FRAME_DURATION_MS)
    }

    @Test fun `capture does not invoke network-facing consumer before authorization`() {
        val capture = Batv1CaptureBuffer()
        capture.arm("generation")
        var forwarded = 0
        capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME)))
        assertEquals(0, forwarded)
        val preRoll = capture.startForwarding { forwarded += 1 }
        assertEquals(1, preRoll.size)
        capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME)))
        assertEquals(1, forwarded)
    }

    @Test fun `per receiver rate policy is bounded and returns to one`() {
        assertEquals(1.00f, batv1PlaybackRate(150))
        assertTrue(batv1PlaybackRate(500) in 1.03f..1.15f)
        assertTrue(batv1PlaybackRate(800) in 1.15f..1.25f)
        assertTrue(batv1PlaybackRate(1_800) in 1.25f..1.40f)
        assertTrue(batv1PlaybackRate(3_500) in 1.40f..BATV1_MAX_PLAYBACK_RATE)
        assertEquals(1.00f, batv1PlaybackRate(250))
    }
}
