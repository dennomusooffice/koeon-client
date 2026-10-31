package com.dennomuso.koeon.core.audio

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class BufferedAudioTimelineTest {
    @Test fun `freeze retains speech tail and never accepts microphone samples after UP`() {
        var processed = 0
        val capture = Batv1CaptureBuffer(processPcm16 = { processed += 1 })
        capture.arm("generation")
        val source = ByteArray(BATV1_BYTES_PER_FRAME + 200) { 7 }
        capture.appendLiveKitPcm(ByteBuffer.wrap(source), 16, 48000, 1, source.size / 2)
        assertTrue(capture.freeze("generation"))
        var forwarded = 0
        val retained = capture.startForwarding { forwarded += 1 }
        capture.appendLiveKitPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME) { 9 }), 16, 48000, 1, 960)
        assertEquals(2, retained.size)
        assertArrayEquals(ByteArray(200) { 7 } + ByteArray(BATV1_BYTES_PER_FRAME - 200), retained.last())
        assertEquals(2, capture.frameCount())
        assertEquals(1, processed)
        assertEquals(0, forwarded)
        assertTrue(capture.freeze("generation"))
        assertEquals(2, capture.frameCount())
    }

    @Test fun `stale freeze cannot stop a new capture generation`() {
        val capture = Batv1CaptureBuffer()
        capture.arm("old")
        assertTrue(capture.freeze("old"))
        capture.arm("new")
        assertEquals(false, capture.freeze("old"))
        capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME)))
        assertEquals(1, capture.frameCount())
    }

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

    @Test fun `BAT capture applies gain to owned PCM before framing and preserves SDK source`() {
        val gain = InputGainProcessor().apply { setMode(InputGainMode.MANUAL); setManualGainDb(6f); beginTransmission() }
        val capture = Batv1CaptureBuffer(gain::processPcm16)
        val source = ByteBuffer.allocate(1920).order(ByteOrder.nativeOrder()).apply {
            repeat(960) { putShort(if (it % 2 == 0) 2000 else -2000) }; rewind()
        }
        capture.arm("gain-test")
        assertTrue(capture.appendLiveKitPcm(source, 16, 48000, 1, 960))
        val output = ByteBuffer.wrap(capture.snapshotFrames().single()).order(ByteOrder.nativeOrder())
        assertEquals(3990, output.short.toInt())
        assertEquals(-3990, output.short.toInt())
        assertEquals(2000, source.getShort(0).toInt())
        assertEquals(0, source.position())
        assertEquals("BATV1_PCM16", gain.snapshot().meterSource)
        assertEquals(960L, gain.snapshot().meterSampleCount)
        assertEquals(6f, gain.snapshot().postKoeonRmsDbfs!! - gain.snapshot().inputRmsDbfs!!, 0.01f)
    }

    @Test fun `BAT capture OFF is bit exact and measures actual sent samples`() {
        val gain = InputGainProcessor()
        val capture = Batv1CaptureBuffer(gain::processPcm16)
        val bytes = ByteArray(1920) { (it % 127).toByte() }
        capture.arm("off")
        capture.appendLiveKitPcm(ByteBuffer.wrap(bytes), 16, 48000, 1, 960)
        assertArrayEquals(bytes, capture.snapshotFrames().single())
        assertEquals(gain.snapshot().inputRmsDbfs, gain.snapshot().postKoeonRmsDbfs)
        capture.stopForwarding()
        capture.appendLiveKitPcm(ByteBuffer.wrap(bytes), 16, 48000, 1, 960)
        assertEquals(960L, gain.snapshot().meterSampleCount)
    }

    @Test fun `unarmed and invalid capture never enters gain processing`() {
        var calls = 0
        val capture = Batv1CaptureBuffer(processPcm16 = { calls++ })
        val source = ByteBuffer.wrap(ByteArray(1920))
        capture.appendLiveKitPcm(source, 16, 48000, 1, 960)
        capture.arm("validations")
        capture.appendLiveKitPcm(source, 16, 16000, 1, 320)
        capture.appendLiveKitPcm(source, 16, 48000, 1, 2000)
        assertEquals(0, calls)
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
