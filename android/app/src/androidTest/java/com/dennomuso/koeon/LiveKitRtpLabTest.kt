package com.dennomuso.koeon

import androidx.test.platform.app.InstrumentationRegistry
import com.dennomuso.koeon.core.audio.RtpPreRollBuffer
import io.livekit.android.LiveKit
import io.livekit.android.audio.AudioBufferCallback
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.room.participant.AudioTrackPublishDefaults
import io.livekit.android.room.track.LocalAudioTrackOptions
import io.livekit.android.room.track.RemoteAudioTrack
import kotlinx.coroutines.*
import livekit.org.webrtc.AudioTrackSink
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeNotNull
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.sin

/** Opt-in real Opus/SFU test. Synthetic tones only; never records microphone data. */
class LiveKitRtpLabTest {
    @Test fun opusWithPreRollOver128kbps() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val role = args.getString("rtpLabRole")
        assumeNotNull(role)
        require(role in setOf("android35", "android36"))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val token = withContext(Dispatchers.IO) {
            JSONObject(URL("http://127.0.0.1:18766/token/$role").readText()).getString("token")
        }
        val room = LiveKit.create(context)
        room.localParticipant.audioTrackCaptureDefaults = LocalAudioTrackOptions(
            echoCancellation = false, autoGainControl = false, noiseSuppression = false, highPassFilter = false)
        room.localParticipant.audioTrackPublishDefaults = AudioTrackPublishDefaults(audioBitrate = 12_000)
        val queue = RtpPreRollBuffer()
        val receivedSamples = AtomicLong()
        val loudSamples = AtomicLong()
        val callbacks = AtomicInteger()
        val subscribed = CompletableDeferred<Unit>()
        val senderReady = CompletableDeferred<Unit>()
        val sink = object : AudioTrackSink {
            override fun onData(audioData: ByteBuffer, bitsPerSample: Int, sampleRate: Int,
                numberOfChannels: Int, numberOfFrames: Int, absoluteCaptureTimestampMs: Long) {
                if (bitsPerSample != 16) return
                val data = audioData.duplicate().order(ByteOrder.nativeOrder())
                while (data.remaining() >= 2) {
                    receivedSamples.incrementAndGet()
                    if (kotlin.math.abs(data.short.toInt()) > 300) loudSamples.incrementAndGet()
                }
            }
        }
        val events = launch {
            room.events.collect { event ->
                when (event) {
                    is RoomEvent.TrackSubscribed -> if (event.track is RemoteAudioTrack) {
                        (event.track as RemoteAudioTrack).addSink(sink)
                        subscribed.complete(Unit)
                        room.localParticipant.publishData("ready".toByteArray(), topic = "rtp-lab")
                    }
                    is RoomEvent.DataReceived -> if (event.topic == "rtp-lab") senderReady.complete(Unit)
                    else -> Unit
                }
            }
        }
        var local: io.livekit.android.room.track.LocalAudioTrack? = null
        try {
            withTimeout(60000) { room.connect("ws://127.0.0.1:18080", token) }
            withTimeout(60000) { while (room.remoteParticipants.isEmpty()) delay(100) }
            local = room.localParticipant.getOrCreateDefaultAudioTrack()
            var phase = 0L
            local.setAudioBufferCallback(object : AudioBufferCallback {
                override fun onBuffer(buffer: ByteBuffer, audioFormat: Int, channelCount: Int,
                    sampleRate: Int, bytesRead: Int, captureTimeNs: Long): Long {
                    require(audioFormat == android.media.AudioFormat.ENCODING_PCM_16BIT)
                    val synthetic = ByteBuffer.allocate(bytesRead).order(ByteOrder.nativeOrder())
                    repeat(bytesRead / (2 * channelCount)) {
                        val value = (sin(phase++ * 2 * Math.PI * 660 / sampleRate) * 6000).toInt().toShort()
                        repeat(channelCount) { synthetic.putShort(value) }
                    }
                    val output = queue.process(synthetic.array(), sampleRate, channelCount, 2)
                    buffer.duplicate().apply { position(0); put(output) }
                    callbacks.incrementAndGet()
                    return 0L
                }
            })
            queue.arm()
            local.prewarm()
            withTimeout(3000) { while (!queue.isConfirmed()) delay(10) }
            assertTrue(queue.markCueBoundary())
            delay(300)
            withTimeout(15000) { room.localParticipant.setMicrophoneEnabled(true) }
            withTimeout(15000) { senderReady.await() }
            assertNull(queue.failure)
            assertTrue(queue.authorize())
            delay(2500)
            queue.freeze()
            withTimeout(7000) { while (!queue.isDrained()) delay(10) }
            delay(300)
            room.localParticipant.setMicrophoneEnabled(false)
            withTimeout(15000) { subscribed.await(); while (loudSamples.get() < 16000) delay(50) }
            assertNull(queue.failure)
            val result = JSONObject(mapOf("role" to role, "callbacks" to callbacks.get(),
                "receivedSamples" to receivedSamples.get(), "loudSamples" to loudSamples.get(),
                "codecTargetBps" to 12000, "queueDrained" to queue.isDrained()))
            withContext(Dispatchers.IO) {
                val c = URL("http://127.0.0.1:18766/result").openConnection() as HttpURLConnection
                c.requestMethod = "POST"; c.doOutput = true
                c.outputStream.use { it.write(result.toString().toByteArray()) }
                assertEquals(200, c.responseCode); c.disconnect()
            }
            // Keep subscriber alive until the other endpoint has also drained.
            delay(3000)
        } finally {
            queue.clear()
            local?.setAudioBufferCallback(null)
            local?.stopPrewarm()
            room.disconnect()
            events.cancelAndJoin()
            room.release()
        }
    }
}
