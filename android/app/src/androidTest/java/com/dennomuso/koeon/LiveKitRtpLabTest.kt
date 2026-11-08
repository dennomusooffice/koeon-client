package com.dennomuso.koeon

import androidx.test.platform.app.InstrumentationRegistry
import com.dennomuso.koeon.core.ptt.*
import com.dennomuso.koeon.core.model.FloorResponse
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
    @Test fun liveKitRealtimePttOver128kbps() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val role = args.getString("rtpLabRole")
        assumeNotNull(role)
        require(role in setOf("android35", "android36"))
        require(android.os.Build.HARDWARE in setOf("ranchu", "goldfish"))
        val endpoint = args.getString("rtpLabUrl") ?: "ws://127.0.0.1:18080"
        require(endpoint in setOf("ws://127.0.0.1:18080", "ws://10.0.2.2:19080"))
        var selectedProtocol = "unknown"
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val token = withContext(Dispatchers.IO) {
            JSONObject(URL("http://127.0.0.1:18766/token/$role").readText()).getString("token")
        }
        val room = LiveKit.create(context)
        room.localParticipant.audioTrackCaptureDefaults = LocalAudioTrackOptions(
            echoCancellation = false, autoGainControl = false, noiseSuppression = false, highPassFilter = false)
        room.localParticipant.audioTrackPublishDefaults = AudioTrackPublishDefaults(audioBitrate = 12_000)
        val receivedSamples = AtomicLong()
        val loudSamples = AtomicLong()
        val callbacks = AtomicInteger()
        val subscribed = CompletableDeferred<Unit>()
        var senderReady = CompletableDeferred<Unit>()
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
            withTimeout(60000) { room.connect(endpoint, token) }
            withTimeout(60000) { while (room.remoteParticipants.isEmpty()) delay(100) }
            local = room.localParticipant.getOrCreateDefaultAudioTrack()
            var phase = 0L
            val source = object : AudioBufferCallback {
                override fun onBuffer(buffer: ByteBuffer, audioFormat: Int, channelCount: Int,
                    sampleRate: Int, bytesRead: Int, captureTimeNs: Long): Long {
                    require(audioFormat == android.media.AudioFormat.ENCODING_PCM_16BIT)
                    val synthetic = ByteBuffer.allocate(bytesRead).order(ByteOrder.nativeOrder())
                    repeat(bytesRead / (2 * channelCount)) {
                        val value = (sin(phase++ * 2 * Math.PI * 660 / sampleRate) * 6000).toInt().toShort()
                        repeat(channelCount) { synthetic.putShort(value) }
                    }
                    buffer.duplicate().apply { position(0); put(synthetic.array()) }
                    callbacks.incrementAndGet()
                    return 0L
                }
            }
            local.setAudioBufferCallback(source)
            local.prewarm()
            val controller = PttController(this,
                floor = object : FloorGateway {
                    override suspend fun acquire() = FloorResponse("granted", leaseId = "lab-lease")
                    override suspend fun renew(leaseId: String) = FloorResponse("renewed", leaseId = leaseId, isOwner = true)
                    override suspend fun release(leaseId: String) = FloorResponse("released")
                },
                microphone = object : MicrophoneGateway {
                    override suspend fun setEnabled(enabled: Boolean) = room.localParticipant.setMicrophoneEnabled(enabled)
                },
                cuePlayer = object : PttCuePlayer {
                    override suspend fun playStart() = Result.success(Unit)
                    override suspend fun playEnd() = Result.success(Unit)
                },
                control = object : PttControlGateway {
                    override suspend fun publishStart(leaseId: String) = runCatching {
                        room.localParticipant.publishData("start".toByteArray(), topic = "rtp-lab-control").getOrThrow()
                    }
                    override suspend fun publishEnd(leaseId: String) = runCatching {
                        room.localParticipant.publishData("end".toByteArray(), topic = "rtp-lab-control").getOrThrow()
                    }
                    override suspend fun awaitRxReady(leaseId: String): RxReadyResult {
                        val ready = withTimeoutOrNull(500) { senderReady.await(); true } == true
                        return RxReadyResult(if (ready) RxReadyReason.ALL_READY else RxReadyReason.SINGLE_TIMEOUT,
                            1, if (ready) 1 else 0, if (ready) 1.0 else 0.0, 0, 500)
                    }
                }, clock = SystemPttClock(), onSnapshot = {})
            try {
                repeat(2) { round ->
                    if (round > 0) {
                        local?.setAudioBufferCallback(null)
                        local?.stopPrewarm()
                        room.disconnect()
                        senderReady = CompletableDeferred()
                        withTimeout(60000) { room.connect(endpoint, token) }
                        local = room.localParticipant.getOrCreateDefaultAudioTrack()
                        local?.setAudioBufferCallback(source)
                        local?.prewarm()
                    }
                    val before = loudSamples.get()
                    withTimeout(15000) { controller.pressDown(true) }
                    assertEquals(PttState.TRANSMITTING, controller.current().state)
                    delay(2500)
                    val stats = CompletableDeferred<String>()
                    room.getPublisherRTCStats { report ->
                        val pair = report.statsMap.values.firstOrNull {
                            it.type == "candidate-pair" && it.members["state"] == "succeeded" && it.members["nominated"] == true
                        }
                        val candidate = pair?.members?.get("remoteCandidateId")?.toString()?.let { report.statsMap[it] }
                        stats.complete(candidate?.members?.get("protocol")?.toString() ?: "unknown")
                    }
                    selectedProtocol = withTimeout(3000) { stats.await() }
                    if (endpoint.contains("10.0.2.2")) assertEquals("udp", selectedProtocol)
                    withTimeout(10000) { controller.pressUp() }
                    assertEquals(PttState.IDLE, controller.current().state)
                    withTimeout(15000) { subscribed.await(); while (loudSamples.get() < before + 16000) delay(50) }
                }
            } finally { controller.stopForSafety("lab cleanup") }
            val result = JSONObject(mapOf("role" to role, "callbacks" to callbacks.get(),
                "receivedSamples" to receivedSamples.get(), "loudSamples" to loudSamples.get(),
                "codecTargetBps" to 12000, "pttIdle" to true, "completedPttRounds" to 2, "selectedProtocol" to selectedProtocol))
            withContext(Dispatchers.IO) {
                val c = URL("http://127.0.0.1:18766/result").openConnection() as HttpURLConnection
                c.requestMethod = "POST"; c.doOutput = true
                c.outputStream.use { it.write(result.toString().toByteArray()) }
                assertEquals(200, c.responseCode); c.disconnect()
            }
            // Keep subscriber alive until the other endpoint has also drained.
            delay(3000)
        } finally {
            local?.setAudioBufferCallback(null)
            local?.stopPrewarm()
            room.disconnect()
            events.cancelAndJoin()
            room.release()
        }
    }
}
