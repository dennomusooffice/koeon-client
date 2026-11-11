package com.dennomuso.koeon.core.livekit

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class ReceiveLevelMeterTest {
    private fun pcm(value: Short = 16384) = ByteBuffer.allocate(16).order(ByteOrder.nativeOrder()).apply { repeat(8) { putShort(value) }; flip() }
    @Test fun rmsSilenceAndBoundsWithoutMutatingBuffer() {
        val buffer = pcm()
        assertEquals(-6.0206f, ReceiveLevelMeter.pcm16Dbfs(buffer, 16, 1, 8)!!, .001f)
        assertEquals(0, buffer.position())
        assertEquals(-96f, ReceiveLevelMeter.pcm16Dbfs(pcm(0), 16, 2, 4)!!, 0f)
        assertNull(ReceiveLevelMeter.pcm16Dbfs(buffer, 32, 1, 8))
        assertNull(ReceiveLevelMeter.pcm16Dbfs(buffer, 16, 0, 8))
        assertNull(ReceiveLevelMeter.pcm16Dbfs(buffer, 16, 1, 9))
        assertNull(ReceiveLevelMeter.pcm16Dbfs(buffer, 16, 8, Int.MAX_VALUE))
    }
    @Test fun sdkBufferPositionDoesNotHideCompleteFrames() {
        val buffer = pcm().apply { position(limit()) }
        assertEquals(-6.0206f, ReceiveLevelMeter.pcm16Dbfs(buffer, 16, 1, 8)!!, .001f)
        assertEquals(16, buffer.position())
    }
    @Test fun rateLimitFreshnessAndDetachedGenerations() {
        val meter = ReceiveLevelMeter(); val first = meter.attach()
        meter.record(first, pcm(), 16, 1, 8, 1000)
        meter.record(first, pcm(0), 16, 1, 8, 1050)
        assertEquals(-6.0206f, meter.value(1050)!!, .001f)
        assertNull(meter.value(1301))
        meter.detach(first); meter.record(first, pcm(), 16, 1, 8, 1400)
        assertNull(meter.value(1400))
        val second = meter.attach(); meter.record(second, pcm(0), 16, 1, 8, 1500)
        assertEquals(-96f, meter.value(1500)!!, 0f)
        meter.reset(); meter.record(second, pcm(), 16, 1, 8, 1600)
        assertNull(meter.value(1600))
    }
    @Test fun multiTrackUsesFreshMaximum() {
        val meter = ReceiveLevelMeter(); val a = meter.attach(); val b = meter.attach()
        meter.record(a, pcm(), 16, 1, 8, 1000); meter.record(b, pcm(8192), 16, 1, 8, 1100)
        assertEquals(-6.0206f, meter.value(1100)!!, .001f)
        meter.detach(a)
        assertEquals(-12.0412f, meter.value(1100)!!, .001f)
    }
}
