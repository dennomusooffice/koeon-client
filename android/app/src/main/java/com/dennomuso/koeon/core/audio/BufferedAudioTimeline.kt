package com.dennomuso.koeon.core.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.PlaybackParams
import android.os.Build
import com.dennomuso.koeon.core.api.KoeonApi
import com.dennomuso.koeon.core.model.Batv1Chunk
import com.dennomuso.koeon.core.model.Batv1PublishRequest
import com.dennomuso.koeon.core.model.Batv1SubscribeRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.UUID
import kotlin.math.roundToInt

const val BATV1_PROTOCOL_VERSION = 1
const val BATV1_SAMPLE_RATE = 48_000
const val BATV1_CHANNELS = 1
const val BATV1_FRAME_DURATION_MS = 20
const val BATV1_BYTES_PER_FRAME = 1_920
const val BATV1_MAX_FRAMES = 300
const val BATV1_MAX_PLAYBACK_RATE = 1.50f

fun batv1PlaybackRate(backlogMs: Int): Float = when {
    backlogMs <= 250 -> 1.00f
    backlogMs <= 750 -> 1.10f
    backlogMs <= 1_500 -> 1.20f
    backlogMs <= 3_000 -> 1.325f
    else -> 1.45f
}

data class BufferedAudioTxDiagnostics(
    val generationId: String? = null,
    val captureArmed: Boolean = false,
    val captureConfirmed: Boolean = false,
    val preRollBufferedFrames: Int = 0,
    val preFloorAudioNetworkEgressFrames: Int = 0,
    val canonicalFramesSent: Int = 0,
    val canonicalBytesSent: Long = 0,
    val canonicalLastSequence: Int = -1,
    val canonicalDroppedFrames: Int = 0,
)

data class BufferedAudioRxDiagnostics(
    val generationId: String? = null,
    val playbackCursor: Int = 0,
    val latestSequence: Int = -1,
    val backlogMs: Int = 0,
    val playbackRate: Float = 1f,
    val missingSequenceCount: Int = 0,
    val duplicateSequenceCount: Int = 0,
    val outOfOrderCount: Int = 0,
    val bufferHeadExpired: Boolean = false,
    val timelineLost: Boolean = false,
    val finalSequence: Int? = null,
)

/** Realtime callback only copies bytes into a bounded RAM ring; it never performs network I/O. */
class Batv1CaptureBuffer {
    private val frames = ArrayDeque<ByteArray>()
    private var partial = ByteArray(0)
    private var armedGeneration: String? = null
    private var firstFrameSignal = Channel<Unit>(Channel.CONFLATED)
    private var dropped = 0
    var onCanonicalFrame: ((ByteArray) -> Unit)? = null

    @Synchronized
    fun arm(generationId: String = UUID.randomUUID().toString()): String {
        frames.clear()
        partial = ByteArray(0)
        dropped = 0
        armedGeneration = generationId
        firstFrameSignal = Channel(Channel.CONFLATED)
        return generationId
    }

    @Synchronized
    fun discard() {
        armedGeneration = null
        frames.clear()
        partial = ByteArray(0)
        onCanonicalFrame = null
    }

    fun appendPostProcessedPcm(source: ByteBuffer) {
        val bytes = ByteArray(source.remaining())
        source.duplicate().get(bytes)
        appendBytes(bytes)
    }

    @Synchronized
    private fun appendBytes(bytes: ByteArray) {
        if (armedGeneration == null) return
        var joined = partial + bytes
        while (joined.size >= BATV1_BYTES_PER_FRAME) {
            val canonical = joined.copyOfRange(0, BATV1_BYTES_PER_FRAME)
            joined = joined.copyOfRange(BATV1_BYTES_PER_FRAME, joined.size)
            if (frames.size == BATV1_MAX_FRAMES) {
                frames.removeFirst()
                dropped += 1
            }
            frames.addLast(canonical)
            firstFrameSignal.trySend(Unit)
            onCanonicalFrame?.invoke(canonical.copyOf())
        }
        partial = joined
    }

    suspend fun awaitCapture(timeoutMs: Long = 750): Boolean =
        synchronized(this) { frames.isNotEmpty() } || withTimeoutOrNull(timeoutMs) { firstFrameSignal.receive(); true } == true

    @Synchronized fun snapshotFrames(): List<ByteArray> = frames.map(ByteArray::copyOf)
    @Synchronized
    fun startForwarding(consumer: (ByteArray) -> Unit): List<ByteArray> {
        onCanonicalFrame = consumer
        return frames.map(ByteArray::copyOf)
    }
    @Synchronized fun frameCount(): Int = frames.size
    @Synchronized fun droppedFrames(): Int = dropped
}

interface BufferedAudioTxGateway {
    suspend fun armAndConfirmCapture(generationId: String): Boolean
    suspend fun authorize(leaseId: String, generationId: String): Boolean
    suspend fun finish(generationId: String): Boolean
    fun discard(generationId: String)
    fun diagnostics(): BufferedAudioTxDiagnostics
}

class HttpBufferedAudioTransmitter(
    private val scope: CoroutineScope,
    private val api: KoeonApi,
    private val capture: Batv1CaptureBuffer,
    private val channelId: String,
    private val sessionId: String,
    private val deviceId: String,
) : BufferedAudioTxGateway {
    private val signal = Channel<Unit>(Channel.CONFLATED)
    private var generationId: String? = null
    private var leaseId: String? = null
    private var nextSequence = 0
    private var sendJob: Job? = null
    private var authorized = false
    private var diagnostics = BufferedAudioTxDiagnostics()

    override suspend fun armAndConfirmCapture(generationId: String): Boolean {
        discard(this.generationId ?: "")
        this.generationId = capture.arm(generationId)
        diagnostics = BufferedAudioTxDiagnostics(generationId = generationId, captureArmed = true)
        val confirmed = capture.awaitCapture()
        diagnostics = diagnostics.copy(captureConfirmed = confirmed, preRollBufferedFrames = capture.frameCount())
        return confirmed
    }

    override suspend fun authorize(leaseId: String, generationId: String): Boolean {
        if (this.generationId != generationId || !diagnostics.captureConfirmed) return false
        this.leaseId = leaseId
        authorized = true
        val pending = ArrayDeque<ByteArray>()
        val initial = capture.startForwarding { frame -> synchronized(pending) { pending.addLast(frame) }; signal.trySend(Unit) }
        pending.addAll(initial)
        sendJob = scope.launch {
            while (isActive) {
                val batch = synchronized(pending) {
                    buildList { repeat(minOf(10, pending.size)) { add(pending.removeFirst()) } }
                }
                if (batch.isEmpty()) {
                    if (!authorized) break
                    withTimeoutOrNull(250) { signal.receive() }
                    continue
                }
                val first = nextSequence
                api.publishBufferedAudio(request(leaseId, generationId, batch, first, null))
                nextSequence += batch.size
                diagnostics = diagnostics.copy(
                    preRollBufferedFrames = initial.size,
                    canonicalFramesSent = nextSequence,
                    canonicalBytesSent = nextSequence.toLong() * BATV1_BYTES_PER_FRAME,
                    canonicalLastSequence = nextSequence - 1,
                    canonicalDroppedFrames = capture.droppedFrames(),
                )
            }
        }
        signal.trySend(Unit)
        return true
    }

    override suspend fun finish(generationId: String): Boolean {
        if (this.generationId != generationId || !authorized) return false
        capture.onCanonicalFrame = null
        authorized = false
        signal.trySend(Unit)
        sendJob?.join()
        val finalSequence = nextSequence - 1
        if (finalSequence >= 0) api.publishBufferedAudio(request(leaseId!!, generationId, emptyList(), nextSequence, finalSequence))
        capture.discard()
        return true
    }

    override fun discard(generationId: String) {
        authorized = false
        sendJob?.cancel()
        sendJob = null
        capture.discard()
        leaseId = null
        this.generationId = null
        nextSequence = 0
    }

    override fun diagnostics() = diagnostics.copy(
        preRollBufferedFrames = capture.frameCount(),
        canonicalDroppedFrames = capture.droppedFrames(),
    )

    private fun request(
        leaseId: String,
        generationId: String,
        frames: List<ByteArray>,
        firstSequence: Int,
        finalSequence: Int?,
    ) = Batv1PublishRequest(
        generationId = generationId,
        channelId = channelId,
        speakerSessionId = sessionId,
        speakerDeviceId = deviceId,
        leaseId = leaseId,
        sessionId = sessionId,
        chunks = frames.mapIndexed { index, bytes -> Batv1Chunk(firstSequence + index, android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)) },
        finalSequence = finalSequence,
    )
}

interface Batv1PcmPlayer {
    fun start()
    fun setRate(rate: Float)
    fun write(bytes: ByteArray)
    fun stop()
}

class AndroidBatv1PcmPlayer : Batv1PcmPlayer {
    private var track: AudioTrack? = null
    override fun start() {
        val minimum = AudioTrack.getMinBufferSize(BATV1_SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(BATV1_SAMPLE_RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(maxOf(minimum, BATV1_BYTES_PER_FRAME * 10))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build().also { it.play() }
    }
    override fun setRate(rate: Float) {
        if (Build.VERSION.SDK_INT >= 23) track?.playbackParams = PlaybackParams().setSpeed(rate.coerceAtMost(BATV1_MAX_PLAYBACK_RATE)).setPitch(1f).setAudioFallbackMode(PlaybackParams.AUDIO_FALLBACK_MODE_FAIL)
    }
    override fun write(bytes: ByteArray) { track?.write(bytes, 0, bytes.size, AudioTrack.WRITE_BLOCKING) }
    override fun stop() { track?.let { runCatching { it.stop() }; it.release() }; track = null }
}

class HttpBufferedAudioReceiver(
    private val scope: CoroutineScope,
    private val api: KoeonApi,
    private val sessionId: String,
    private val playerFactory: () -> Batv1PcmPlayer = ::AndroidBatv1PcmPlayer,
) {
    private var job: Job? = null
    private var diagnostics = BufferedAudioRxDiagnostics()
    fun start(generationId: String) {
        job?.cancel()
        job = scope.launch {
            var cursor = 0
            var last = -1
            val player = playerFactory().also { it.start() }
            try {
                while (isActive) {
                    val response = runCatching { api.subscribeBufferedAudio(Batv1SubscribeRequest(sessionId, generationId, cursor)) }.getOrElse {
                        delay(100); continue
                    }
                    if (response.bufferHeadExpired) diagnostics = diagnostics.copy(bufferHeadExpired = true)
                    for (chunk in response.chunks) {
                        when {
                            chunk.sequence < cursor -> { diagnostics = diagnostics.copy(duplicateSequenceCount = diagnostics.duplicateSequenceCount + 1); continue }
                            chunk.sequence > cursor -> diagnostics = diagnostics.copy(missingSequenceCount = diagnostics.missingSequenceCount + (chunk.sequence - cursor))
                        }
                        if (chunk.sequence <= last) diagnostics = diagnostics.copy(outOfOrderCount = diagnostics.outOfOrderCount + 1)
                        val backlog = ((response.latestSequence - chunk.sequence).coerceAtLeast(0)) * BATV1_FRAME_DURATION_MS
                        val rate = batv1PlaybackRate(backlog)
                        player.setRate(rate)
                        player.write(android.util.Base64.decode(chunk.payloadBase64, android.util.Base64.DEFAULT))
                        last = chunk.sequence
                        cursor = chunk.sequence + 1
                        diagnostics = diagnostics.copy(generationId, cursor, response.latestSequence, backlog, rate, finalSequence = response.finalSequence)
                    }
                    if (response.timelineEnded && response.finalSequence != null && cursor > response.finalSequence) break
                    if (response.chunks.isEmpty()) delay(40)
                }
            } finally { player.setRate(1f); player.stop() }
        }
    }
    fun stop() { job?.cancel(); job = null }
    fun diagnostics() = diagnostics
}
