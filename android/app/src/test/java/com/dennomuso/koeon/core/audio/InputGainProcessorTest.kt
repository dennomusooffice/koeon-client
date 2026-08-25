package com.dennomuso.koeon.core.audio

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InputGainProcessorTest {
    @Test
    fun `default mode is transparent with zero effective gain`() {
        val processor = InputGainProcessor()

        assertEquals(InputGainMode.OFF, processor.snapshot().mode)
        assertEquals(0f, processor.snapshot().effectiveGainDb, 0f)
    }

    @Test
    fun `resetting route calibration does not enable gain`() {
        val processor = InputGainProcessor().apply {
            setRoute("Built-in")
            resetProfile()
        }

        assertEquals(InputGainMode.OFF, processor.snapshot().mode)
        assertEquals(0f, processor.snapshot().effectiveGainDb, 0f)
    }

    @Test
    fun `off is transparent for ordinary samples`() {
        val processor = InputGainProcessor().apply { setMode(InputGainMode.OFF) }
        val buffer = samples(1_000, -2_000, 12_000)

        processor.processAudio(1, 3, buffer)

        assertEquals(listOf<Short>(1_000, -2_000, 12_000), values(buffer))
    }

    @Test
    fun `manual gain handles positive and negative PCM without buffering`() {
        val processor = InputGainProcessor().apply {
            setMode(InputGainMode.MANUAL)
            setManualGainDb(6f)
            beginTransmission()
        }
        val buffer = samples(2_000, -2_000)

        processor.processAudio(1, 2, buffer)

        val output = values(buffer)
        assertTrue(abs(output[0] - 3_991) < 8)
        assertTrue(abs(output[1] + 3_991) < 8)
        assertEquals(0, buffer.position())
    }

    @Test
    fun `minus six dB scales stereo channels without overflow`() {
        val processor = InputGainProcessor().apply {
            setMode(InputGainMode.MANUAL)
            setManualGainDb(-6f)
            beginTransmission()
        }
        val buffer = samples(10_000, -10_000, 32_000, -32_000)
        processor.processAudio(1, 2, buffer)
        val output = values(buffer)
        assertTrue(abs(output[0] - 5_011) < 8)
        assertTrue(abs(output[1] + 5_011) < 8)
        assertTrue(output.all { it in Short.MIN_VALUE..Short.MAX_VALUE })
        val snapshot = processor.snapshot()
        assertTrue(snapshot.postKoeonRmsDbfs!! < snapshot.inputRmsDbfs!!)
        assertTrue(snapshot.postKoeonPeakDbfs!! < snapshot.inputPeakDbfs!!)
    }

    @Test
    fun `soft limiter stays below full scale and counts hits`() {
        val processor = InputGainProcessor().apply {
            setMode(InputGainMode.MANUAL)
            setManualGainDb(12f)
            beginTransmission()
        }
        val buffer = samples(30_000, -30_000)

        processor.processAudio(1, 2, buffer)

        assertTrue(values(buffer).all { abs(it.toInt()) < 30_000 })
        assertTrue(processor.snapshot().limiterHitCount >= 2)
        assertTrue(processor.snapshot().postKoeonPeakDbfs!! < -0.9f)
    }

    @Test
    fun `calibration recommendation and auto adaptation are bounded`() {
        assertEquals(12f, InputGainProcessor.recommendedGain(-50f), 0f)
        assertEquals(-6f, InputGainProcessor.recommendedGain(-5f), 0f)
        assertEquals(1f, InputGainProcessor.nextAutoTrim(0f, -30f), 0f)
        assertEquals(-1f, InputGainProcessor.nextAutoTrim(0f, -5f), 0f)
        assertEquals(12f, InputGainProcessor.nextAutoTrim(12f, -40f), 0f)
        assertEquals(3f, InputGainProcessor.nextAutoTrim(4f, -30f, -0.1f, 0.0), 0f)
        assertEquals(3f, InputGainProcessor.nextAutoTrim(4f, -30f, -8f, 0.02), 0f)
    }

    @Test
    fun `profiles remain isolated by observed route`() {
        val repository = MemoryProfiles()
        val processor = InputGainProcessor(repository)
        processor.setRoute("Bluetooth:alpha")
        processor.setManualGainDb(7f)
        processor.setRoute("Built-in microphone")
        processor.setManualGainDb(-2f)
        processor.setRoute("Bluetooth:alpha")

        assertEquals(7f, processor.snapshot().manualGainDb, 0f)
        assertEquals("Bluetooth:alpha", processor.snapshot().route)
        processor.resetProfile()
        assertEquals(0f, processor.snapshot().manualGainDb, 0f)
    }

    @Test
    fun `short or limiter dominated utterances do not raise auto trim`() {
        val repository = MemoryProfiles().apply {
            save(AudioDeviceProfile("Built-in", "Built-in", "Built-in", autoTrimDb = 2f))
        }
        val processor = InputGainProcessor(repository).apply { setRoute("Built-in"); setMode(InputGainMode.AUTO) }
        processor.beginTransmission()
        processor.processAudio(1, 100, samples(*IntArray(100) { 100 }))
        processor.endTransmission()
        assertEquals(2f, processor.snapshot().autoTrimDb, 0f)

        processor.beginTransmission()
        processor.processAudio(1, 5_000, samples(*IntArray(5_000) { 32_000 }))
        processor.endTransmission()
        assertEquals(1f, processor.snapshot().autoTrimDb, 0f)
    }

    @Test
    fun `auto trim reduces one decibel for peak or limiter saturation`() {
        assertEquals(3f, InputGainProcessor.nextAutoTrim(4f, -24f, -0.2f, 0.0), 0f)
        assertEquals(3f, InputGainProcessor.nextAutoTrim(4f, -24f, -10f, 0.02), 0f)
        assertEquals(5f, InputGainProcessor.nextAutoTrim(4f, -24f, -10f, 0.0), 0f)
    }

    private fun samples(vararg values: Int): ByteBuffer =
        ByteBuffer.allocateDirect(values.size * 2).order(ByteOrder.nativeOrder()).also { buffer ->
            values.forEach { buffer.putShort(it.toShort()) }
            buffer.rewind()
        }

    private fun values(buffer: ByteBuffer): List<Short> =
        buffer.duplicate().order(ByteOrder.nativeOrder()).also { it.rewind() }
            .let { view -> buildList { while (view.remaining() >= 2) add(view.short) } }

    private class MemoryProfiles : AudioDeviceProfileRepository {
        private val values = mutableMapOf<String, AudioDeviceProfile>()
        override fun load(route: String): AudioDeviceProfile = values[route]
            ?: AudioDeviceProfile(route, route, route.substringBefore(':'))
        override fun save(profile: AudioDeviceProfile) { values[profile.displayName] = profile }
        override fun reset(route: String) { values.remove(route) }
    }
}
