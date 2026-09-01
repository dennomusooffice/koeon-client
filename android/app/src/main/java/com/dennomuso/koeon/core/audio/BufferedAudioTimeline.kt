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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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
    val captureSource: String = "LIVEKIT_PREWARMED_TRACK_SINK",
    val captureState: String = "IDLE",
    val captureArmed: Boolean = false,
    val captureConfirmed: Boolean = false,
    val captureArmedAtEpochMs: Long? = null,
    val firstPcmAtEpochMs: Long? = null,
    val captureConfirmedAtEpochMs: Long? = null,
    val captureConfirmMs: Long? = null,
    val preRollBufferedFrames: Int = 0,
    val preFloorAudioNetworkEgressFrames: Int = 0,
    val canonicalFramesSent: Int = 0,
    val canonicalBytesSent: Long = 0,
    val canonicalLastSequence: Int = -1,
    val canonicalDroppedFrames: Int = 0,
    val lastErrorCode: String? = null,
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
    private var armedAtEpochMs: Long? = null
    private var firstPcmAtEpochMs: Long? = null
    private var lastErrorCode: String? = null
    var onCanonicalFrame: ((ByteArray) -> Unit)? = null

    @Synchronized
    fun arm(generationId: String = UUID.randomUUID().toString()): String {
        frames.clear()
        partial = ByteArray(0)
        dropped = 0
        armedAtEpochMs = System.currentTimeMillis()
        firstPcmAtEpochMs = null
        lastErrorCode = null
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

    /** Defines canonical seq0 after the audible start cue. */
    @Synchronized
    fun markCueBoundary() {
        frames.clear()
        partial = ByteArray(0)
        dropped = 0
    }

    /**
     * Receives the fixed LiveKit LocalAudioTrack sink format. This method only
     * copies microphone bytes into RAM and never performs network I/O.
     */
    fun appendLiveKitPcm(
        source: ByteBuffer,
        bitsPerSample: Int,
        sampleRate: Int,
        channels: Int,
        frames: Int,
    ): Boolean {
        if (bitsPerSample != 16 || sampleRate != BATV1_SAMPLE_RATE || channels != BATV1_CHANNELS || frames <= 0) {
            synchronized(this) { lastErrorCode = "BATV1_CAPTURE_FORMAT_UNSUPPORTED" }
            return false
        }
        val expectedBytes = frames * channels * (bitsPerSample / 8)
        val input = source.duplicate()
        input.rewind()
        if (input.remaining() < expectedBytes) {
            synchronized(this) { lastErrorCode = "BATV1_CAPTURE_BUFFER_SHORT" }
            return false
        }
        val bytes = ByteArray(expectedBytes)
        input.get(bytes)
        appendBytes(bytes)
        return true
    }

    fun appendPostProcessedPcm(source: ByteBuffer) {
        val bytes = ByteArray(source.remaining())
        source.duplicate().get(bytes)
        appendBytes(bytes)
    }

    @Synchronized
    private fun appendBytes(bytes: ByteArray) {
        if (armedGeneration == null) return
        if (bytes.isNotEmpty() && firstPcmAtEpochMs == null) firstPcmAtEpochMs = System.currentTimeMillis()
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
    @Synchronized fun stopForwarding() { onCanonicalFrame = null }
    @Synchronized fun frameCount(): Int = frames.size
    @Synchronized fun droppedFrames(): Int = dropped
    @Synchronized fun armedAtEpochMs(): Long? = armedAtEpochMs
    @Synchronized fun firstPcmAtEpochMs(): Long? = firstPcmAtEpochMs
    @Synchronized fun lastErrorCode(): String? = lastErrorCode
}

interface BufferedAudioTxGateway {
    suspend fun armAndConfirmCapture(generationId: String): Boolean
    fun markCueBoundary(generationId: String): Boolean
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
    private val onFailure: (String) -> Unit = {},
) : BufferedAudioTxGateway {
    private val signal = Channel<Unit>(Channel.CONFLATED)
    private var generationId: String? = null
    private var leaseId: String? = null
    private var nextSequence = 0
    private val pending = ArrayDeque<ByteArray>()
    private var sendJob: Job? = null
    private var teardownJob: Job? = null
    @Volatile private var authorized = false
    private val lifecycleMutex = Mutex()
    @Volatile private var diagnostics = BufferedAudioTxDiagnostics()

    override suspend fun armAndConfirmCapture(generationId: String): Boolean {
        teardownJob?.join()
        lifecycleMutex.withLock {
            this.generationId = capture.arm(generationId)
            leaseId = null
            nextSequence = 0
            authorized = false
            diagnostics = BufferedAudioTxDiagnostics(
                generationId = generationId,
                captureState = "STARTING",
                captureArmed = true,
                captureArmedAtEpochMs = capture.armedAtEpochMs(),
            )
        }
        Batv1CrashBreadcrumbs.record("TX", "TX_PREPARE", generationId)
        Batv1CrashBreadcrumbs.record("TX", "TX_CAPTURE_START", generationId)
        val confirmed = capture.awaitCapture()
        val confirmedAt = if (confirmed) System.currentTimeMillis() else null
        diagnostics = diagnostics.copy(
            captureState = if (confirmed) "ACTIVE" else "ERROR",
            captureConfirmed = confirmed,
            firstPcmAtEpochMs = capture.firstPcmAtEpochMs(),
            captureConfirmedAtEpochMs = confirmedAt,
            captureConfirmMs = confirmedAt?.minus(capture.armedAtEpochMs() ?: confirmedAt),
            preRollBufferedFrames = capture.frameCount(),
            lastErrorCode = if (confirmed) null else capture.lastErrorCode() ?: "BATV1_CAPTURE_ZERO_FRAMES",
        )
        Batv1CrashBreadcrumbs.record(
            "TX",
            if (confirmed) "TX_CAPTURE_CONFIRMED" else "TX_CAPTURE_FAILED",
            generationId,
            resultClass = if (confirmed) "OK" else diagnostics.lastErrorCode ?: "CAPTURE_FAILED",
        )
        return confirmed
    }

    override fun markCueBoundary(generationId: String): Boolean {
        if (this.generationId != generationId || !diagnostics.captureConfirmed) return false
        capture.markCueBoundary()
        diagnostics = diagnostics.copy(preRollBufferedFrames = 0)
        return true
    }

    override suspend fun authorize(leaseId: String, generationId: String): Boolean {
        teardownJob?.join()
        if (this.generationId != generationId || !diagnostics.captureConfirmed) return false
        this.leaseId = leaseId
        authorized = true
        diagnostics = diagnostics.copy(captureState = "ACTIVE")
        Batv1CrashBreadcrumbs.record("TX", "TX_AUTHORIZED", generationId)
        synchronized(pending) { pending.clear() }
        val initial = capture.startForwarding { frame -> synchronized(pending) { pending.addLast(frame) }; signal.trySend(Unit) }
        synchronized(pending) { pending.addAll(initial) }
        sendJob = scope.launch {
            try {
                while (isActive) {
                    val batch = synchronized(pending) {
                        buildList { repeat(minOf(10, pending.size)) { add(pending.removeFirst()) } }
                    }
                    if (batch.isEmpty()) {
                        if (!authorized) break
                        withTimeoutOrNull(250) { signal.receive() }
                        continue
                    }
                    publishBatch(leaseId, generationId, batch, initial.size)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                authorized = false
                capture.stopForwarding()
                diagnostics = diagnostics.copy(captureState = "FAILED", lastErrorCode = "BATV1_PUBLISH_FAILED")
                Batv1CrashBreadcrumbs.record("TX", "TX_BATCH_FAILED", generationId, resultClass = error.javaClass.simpleName)
                onFailure("BATV1_PUBLISH_FAILED")
            }
        }
        signal.trySend(Unit)
        return true
    }

    override suspend fun finish(generationId: String): Boolean {
        if (this.generationId != generationId || !authorized) return false
        diagnostics = diagnostics.copy(captureState = "FINISHING")
        Batv1CrashBreadcrumbs.record("TX", "TX_FINISH_BEGIN", generationId)
        capture.stopForwarding()
        authorized = false
        signal.trySend(Unit)
        sendJob?.join()
        if (diagnostics.lastErrorCode != null) {
            boundedCleanup(generationId, "FAILED")
            return false
        }
        return try {
            while (true) {
                val batch = synchronized(pending) {
                    buildList { repeat(minOf(10, pending.size)) { add(pending.removeFirst()) } }
                }
                if (batch.isEmpty()) break
                publishBatch(requireNotNull(leaseId), generationId, batch, diagnostics.preRollBufferedFrames)
            }
            val finalSequence = nextSequence - 1
            if (finalSequence >= 0) {
                Batv1CrashBreadcrumbs.record("TX", "TX_FINAL_MARKER_BEGIN", generationId)
                api.publishBufferedAudio(request(requireNotNull(leaseId), generationId, emptyList(), nextSequence, finalSequence))
                Batv1CrashBreadcrumbs.record("TX", "TX_FINAL_MARKER_END", generationId)
            }
            boundedCleanup(generationId, "STOPPED")
            true
        } catch (cancelled: CancellationException) {
            boundedCleanup(generationId, "STOPPED")
            throw cancelled
        } catch (error: Throwable) {
            diagnostics = diagnostics.copy(lastErrorCode = "BATV1_FINAL_MARKER_FAILED")
            Batv1CrashBreadcrumbs.record("TX", "TX_FINAL_MARKER_FAILED", generationId, resultClass = error.javaClass.simpleName)
            boundedCleanup(generationId, "FAILED")
            onFailure("BATV1_FINAL_MARKER_FAILED")
            false
        }
    }

    override fun discard(generationId: String) {
        if (generationId.isNotEmpty() && this.generationId != generationId) return
        authorized = false
        capture.stopForwarding()
        val targetGeneration = this.generationId
        val previous = sendJob
        previous?.cancel()
        teardownJob = scope.launch {
            previous?.cancelAndJoin()
            lifecycleMutex.withLock {
                if (targetGeneration == this@HttpBufferedAudioTransmitter.generationId) {
                    boundedCleanup(targetGeneration, "STOPPED")
                }
            }
        }
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

    private fun boundedCleanup(generationId: String?, state: String) {
        capture.stopForwarding()
        capture.discard()
        sendJob = null
        authorized = false
        leaseId = null
        this.generationId = null
        nextSequence = 0
        synchronized(pending) { pending.clear() }
        diagnostics = diagnostics.copy(captureState = state)
        Batv1CrashBreadcrumbs.record("TX", "TX_CAPTURE_STOP_END", generationId, resultClass = state)
    }

    private suspend fun publishBatch(
        leaseId: String,
        generationId: String,
        batch: List<ByteArray>,
        preRollFrames: Int,
    ) {
        val first = nextSequence
        Batv1CrashBreadcrumbs.record("TX", "TX_BATCH_BEGIN", generationId)
        api.publishBufferedAudio(request(leaseId, generationId, batch, first, null))
        nextSequence += batch.size
        diagnostics = diagnostics.copy(
            preRollBufferedFrames = preRollFrames,
            canonicalFramesSent = nextSequence,
            canonicalBytesSent = nextSequence.toLong() * BATV1_BYTES_PER_FRAME,
            canonicalLastSequence = nextSequence - 1,
            canonicalDroppedFrames = capture.droppedFrames(),
        )
        Batv1CrashBreadcrumbs.record("TX", "TX_BATCH_END", generationId)
    }
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
        stop()
        val minimum = AudioTrack.getMinBufferSize(BATV1_SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(BATV1_SAMPLE_RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(maxOf(minimum, BATV1_BYTES_PER_FRAME * 10))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build().also { it.play() }
    }
    override fun setRate(rate: Float) {
        if (Build.VERSION.SDK_INT >= 23) runCatching {
            track?.playbackParams = PlaybackParams()
                .setSpeed(rate.coerceIn(1f, BATV1_MAX_PLAYBACK_RATE))
                .setPitch(1f)
                .setAudioFallbackMode(PlaybackParams.AUDIO_FALLBACK_MODE_FAIL)
        }.onFailure {
            Batv1CrashBreadcrumbs.record("RX", "RX_PLAYBACK_RATE_FALLBACK", resultClass = it.javaClass.simpleName)
            runCatching { track?.playbackParams = PlaybackParams().setSpeed(1f).setPitch(1f) }
        }
    }
    override fun write(bytes: ByteArray) {
        val written = track?.write(bytes, 0, bytes.size, AudioTrack.WRITE_BLOCKING) ?: error("BATV1_AUDIO_TRACK_MISSING")
        check(written == bytes.size) { "BATV1_AUDIO_TRACK_SHORT_WRITE" }
    }
    override fun stop() {
        val active = track ?: return
        track = null
        runCatching { active.stop() }
        runCatching { active.release() }
    }
}

class HttpBufferedAudioReceiver(
    private val scope: CoroutineScope,
    private val api: KoeonApi,
    private val sessionId: String,
    private val playerFactory: () -> Batv1PcmPlayer = ::AndroidBatv1PcmPlayer,
    private val onFailure: (String) -> Unit = {},
) {
    private var job: Job? = null
    @Volatile private var generationToken = 0L
    private val workerScope = CoroutineScope(
        SupervisorJob(scope.coroutineContext[Job]) + Dispatchers.IO.limitedParallelism(1),
    )
    @Volatile private var diagnostics = BufferedAudioRxDiagnostics()
    fun start(generationId: String) {
        val previous = job
        previous?.cancel()
        generationToken += 1
        val token = generationToken
        job = workerScope.launch {
            previous?.cancelAndJoin()
            if (token != generationToken) return@launch
            var cursor = 0
            var last = -1
            val player = playerFactory()
            diagnostics = BufferedAudioRxDiagnostics(generationId = generationId)
            Batv1CrashBreadcrumbs.record("RX", "RX_START", generationId, "AUDIO_SERIAL_WORKER")
            try {
                Batv1CrashBreadcrumbs.record("RX", "RX_PLAYER_PREPARE", generationId, "AUDIO_SERIAL_WORKER")
                player.start()
                Batv1CrashBreadcrumbs.record("RX", "RX_PLAYER_START", generationId, "AUDIO_SERIAL_WORKER")
                while (isActive) {
                    Batv1CrashBreadcrumbs.record("RX", "RX_SUBSCRIBE_BEGIN", generationId, "AUDIO_SERIAL_WORKER")
                    val response = runCatching { api.subscribeBufferedAudio(Batv1SubscribeRequest(sessionId, generationId, cursor)) }.getOrElse {
                        delay(100); continue
                    }
                    Batv1CrashBreadcrumbs.record("RX", "RX_SUBSCRIBE_END", generationId, "AUDIO_SERIAL_WORKER")
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
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                diagnostics = diagnostics.copy(timelineLost = true)
                Batv1CrashBreadcrumbs.record("RX", "RX_FAILED", generationId, "AUDIO_SERIAL_WORKER", error.javaClass.simpleName)
                onFailure("BATV1_RX_${error.javaClass.simpleName.uppercase()}")
            } finally {
                Batv1CrashBreadcrumbs.record("RX", "RX_PLAYER_STOP_BEGIN", generationId, "AUDIO_SERIAL_WORKER")
                runCatching { player.setRate(1f) }
                runCatching { player.stop() }
                Batv1CrashBreadcrumbs.record("RX", "RX_PLAYER_STOP_END", generationId, "AUDIO_SERIAL_WORKER")
            }
        }
    }
    fun stop() { generationToken += 1; job?.cancel() }
    suspend fun stopAndAwait() { generationToken += 1; job?.cancelAndJoin(); job = null }
    fun shutdown() { generationToken += 1; job?.cancel(); job = null; workerScope.cancel() }
    suspend fun shutdownAndAwait() { stopAndAwait(); workerScope.cancel() }
    fun diagnostics() = diagnostics
}
