package com.dennomuso.koeon.core.ptt

import com.dennomuso.koeon.core.model.FloorResponse
import com.dennomuso.koeon.core.audio.BufferedAudioTxGateway
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.util.UUID

const val FLOOR_LEASE_TTL_MS = 3_000L
const val FLOOR_RENEW_INTERVAL_MS = 1_000L
const val MAX_CONTINUOUS_TX_MS = 60_000L
const val TX_RELEASE_HANG_MS = 180L
const val TX_POST_MUTE_FLUSH_MS = 80L

enum class PttState {
    IDLE,
    REQUESTING_FLOOR,
    TRANSMITTING,
    BUSY,
    RX_ONLY,
    ERROR,
}

data class PttTiming(
    val pttDownAt: Instant? = null,
    val localUiFeedbackAt: Instant? = null,
    val floorGrantedAt: Instant? = null,
    val cueStartAt: Instant? = null,
    val cueEndAt: Instant? = null,
    val trackEnabledAt: Instant? = null,
    val controlStartSentAt: Instant? = null,
    val readyWaitStartedAt: Instant? = null,
    val readyFirstAt: Instant? = null,
    val readyAllAt: Instant? = null,
    val localStartCueCompletedAt: Instant? = null,
    val floorLatencyMs: Long? = null,
    val localEnableLatencyMs: Long? = null,
    val readyWaitMs: Long? = null,
) {
    val localUiFeedbackLatencyMs: Long?
        get() = if (pttDownAt == null || localUiFeedbackAt == null) null
        else (localUiFeedbackAt.toEpochMilli() - pttDownAt.toEpochMilli()).coerceAtLeast(0L)
}

data class PttSnapshot(
    val state: PttState = PttState.IDLE,
    val leaseId: String? = null,
    val currentSpeaker: String? = null,
    val lastError: String? = null,
    val startCueResult: String = "Not played",
    val endCueResult: String = "Not played",
    val controlStartResult: String = "Not sent",
    val controlEndResult: String = "Not sent",
    val statusCueResult: String = "Not played",
    val rxReadyExpectedCount: Int = 0,
    val rxReadyReceivedCount: Int = 0,
    val rxReadyRatioAtMicOn: Double? = null,
    val rxReadyLateCount: Int = 0,
    val rxReadyTimedOut: Boolean = false,
    val timing: PttTiming = PttTiming(),
)

interface FloorGateway {
    suspend fun acquire(): FloorResponse
    suspend fun renew(leaseId: String): FloorResponse
    suspend fun release(leaseId: String): FloorResponse
}

interface MicrophoneGateway {
    suspend fun setEnabled(enabled: Boolean): Boolean
}

interface PttCuePlayer {
    suspend fun playStart(): Result<Unit>
    suspend fun playEnd(): Result<Unit>
    suspend fun playBusy(): Result<Unit> = Result.success(Unit)
    suspend fun playError(): Result<Unit> = Result.success(Unit)
}

interface PttClock {
    fun now(): Instant
    fun elapsedRealtimeMs(): Long
}

class SystemPttClock : PttClock {
    override fun now(): Instant = Instant.now()
    override fun elapsedRealtimeMs(): Long = android.os.SystemClock.elapsedRealtime()
}

class PttController(
    private val scope: CoroutineScope,
    private val floor: FloorGateway,
    private val microphone: MicrophoneGateway,
    private val cuePlayer: PttCuePlayer,
    private val control: PttControlGateway = NoopPttControlGateway,
    private val bufferedAudio: BufferedAudioTxGateway? = null,
    private val clock: PttClock,
    private val onSnapshot: (PttSnapshot) -> Unit,
) {
    private val transitionMutex = Mutex()
    private var snapshot = PttSnapshot()
    private var held = false
    private var generation = 0L
    private var renewJob: Job? = null
    private var maxTxJob: Job? = null
    private val safetyStopSignal = Channel<Unit>(Channel.CONFLATED)
    private var activeBufferedGenerationId: String? = null

    fun current(): PttSnapshot = snapshot

    suspend fun rejectForAudioUnavailable() {
        playStatusCue("ERROR", cuePlayer.playError())
    }

    suspend fun rejectForRemoteBusy() {
        playStatusCue("BUSY", cuePlayer.playBusy())
    }

    fun setRxOnly() {
        held = false
        discardActiveBuffered()
        control.cancelRxReady()
        cancelTimers()
        update(PttSnapshot(state = PttState.RX_ONLY))
    }

    fun reset(canTransmit: Boolean = true) {
        held = false
        discardActiveBuffered()
        generation += 1
        control.cancelRxReady()
        cancelTimers()
        update(PttSnapshot(state = if (canTransmit) PttState.IDLE else PttState.RX_ONLY))
    }

    suspend fun pressDown(canTransmit: Boolean) {
        if (!canTransmit) {
            setRxOnly()
            return
        }
        transitionMutex.withLock {
            safetyStopSignal.tryReceive().getOrNull()
            if (held || snapshot.state == PttState.REQUESTING_FLOOR || snapshot.state == PttState.TRANSMITTING) return
            held = true
            generation += 1
            val requestGeneration = generation
            val downAt = clock.now()
            val downMark = clock.elapsedRealtimeMs()
            update(
                snapshot.copy(
                    state = PttState.REQUESTING_FLOOR,
                    leaseId = null,
                    lastError = null,
                    timing = PttTiming(pttDownAt = downAt, localUiFeedbackAt = clock.now()),
                ),
            )
            val bufferedGenerationId = bufferedAudio?.let { gateway ->
                UUID.randomUUID().toString().also { id ->
                    if (!gateway.armAndConfirmCapture(id)) {
                        held = false
                        gateway.discard(id)
                        update(snapshot.copy(state = PttState.ERROR, lastError = "Buffered capture could not be armed"))
                        playStatusCue("ERROR", cuePlayer.playError())
                        return
                    }
                    activeBufferedGenerationId = id
                    if (!gateway.markCueBoundary(id)) {
                        held = false
                        gateway.discard(id)
                        update(snapshot.copy(state = PttState.ERROR, lastError = "Buffered cue boundary could not be established"))
                        playStatusCue("ERROR", cuePlayer.playError())
                        return
                    }
                    val cueStart = clock.now()
                    val cueResult = cuePlayer.playStart()
                    val cueEnd = clock.now()
                    update(snapshot.copy(
                        startCueResult = cueResult.fold({ "Played" }, { "Failed: ${it.message ?: "unknown"}" }),
                        timing = snapshot.timing.copy(cueStartAt = cueStart, cueEndAt = cueEnd, localStartCueCompletedAt = cueEnd),
                    ))
                }
            }
            val acquired = runCatching { floor.acquire() }.getOrElse { error ->
                held = false
                bufferedGenerationId?.let { bufferedAudio?.discard(it) }
                activeBufferedGenerationId = null
                update(snapshot.copy(state = PttState.ERROR, lastError = error.message ?: "Floor acquire failed"))
                playStatusCue("ERROR", cuePlayer.playError())
                return
            }
            if (acquired.outcome == "busy") {
                held = false
                bufferedGenerationId?.let { bufferedAudio?.discard(it) }
                activeBufferedGenerationId = null
                update(
                    snapshot.copy(
                        state = PttState.BUSY,
                        leaseId = null,
                        currentSpeaker = acquired.owner?.name,
                    ),
                )
                playStatusCue("BUSY", cuePlayer.playBusy())
                return
            }

            val leaseId = acquired.leaseId
            if (acquired.outcome != "granted" || leaseId.isNullOrBlank()) {
                held = false
                bufferedGenerationId?.let { bufferedAudio?.discard(it) }
                activeBufferedGenerationId = null
                update(snapshot.copy(state = PttState.ERROR, lastError = "Floor grant did not include a Lease ID"))
                playStatusCue("ERROR", cuePlayer.playError())
                return
            }

            val grantedAt = acquired.acquiredAt?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: clock.now()
            val grantedMark = clock.elapsedRealtimeMs()
            update(
                snapshot.copy(
                    leaseId = leaseId,
                    currentSpeaker = acquired.owner?.name,
                    timing = snapshot.timing.copy(
                        floorGrantedAt = grantedAt,
                        floorLatencyMs = grantedMark - downMark,
                    ),
                ),
            )
            startRenewal(leaseId, requestGeneration)
            startMaxTxGuard(leaseId, requestGeneration, acquired.maxTxExpiresAt)

            if (!held || requestGeneration != generation) {
                discardActiveBuffered()
                runCatching { floor.release(leaseId) }
                update(snapshot.copy(state = PttState.IDLE, leaseId = null, currentSpeaker = null))
                return
            }

            control.prepareRxReady(
                leaseId,
                acquired.rxReadyExpectedSessionIds,
                acquired.rxReadyExpectedDeviceIds,
            )
            val controlResult = if (bufferedGenerationId != null) {
                control.publishBufferedStart(leaseId, bufferedGenerationId)
            } else {
                control.publishStart(leaseId)
            }
            val controlSentAt = clock.now()
            update(snapshot.copy(controlStartResult = controlResult.fold(
                { "Sent" },
                { "Failed: ${it.message ?: "unknown"}" },
            ), timing = snapshot.timing.copy(
                controlStartSentAt = controlSentAt,
                readyWaitStartedAt = controlSentAt,
            )))
            val ready = control.awaitRxReady(leaseId)
            update(snapshot.copy(
                rxReadyExpectedCount = ready.expectedCount,
                rxReadyReceivedCount = ready.receivedCountAtMicOn,
                rxReadyRatioAtMicOn = ready.ratioAtMicOn,
                rxReadyLateCount = ready.lateCount,
                rxReadyTimedOut = ready.timedOut,
                timing = snapshot.timing.copy(
                    readyWaitMs = ready.waitMs,
                    readyFirstAt = ready.firstReadyAtMs?.let(Instant::ofEpochMilli),
                    readyAllAt = ready.allReadyAtMs?.let(Instant::ofEpochMilli),
                ),
            ))
            if (ready.reason == RxReadyReason.CANCELLED || !held || requestGeneration != generation) {
                discardActiveBuffered()
                runCatching { control.publishEnd(leaseId) }
                runCatching { floor.release(leaseId) }
                update(snapshot.copy(state = PttState.IDLE, leaseId = null, currentSpeaker = null))
                return
            }

            if (bufferedGenerationId == null) {
                val cueStart = clock.now()
                val cueResult = cuePlayer.playStart()
                val cueEnd = clock.now()
                update(snapshot.copy(
                    startCueResult = cueResult.fold({ "Played" }, { "Failed: ${it.message ?: "unknown"}" }),
                    timing = snapshot.timing.copy(cueStartAt = cueStart, cueEndAt = cueEnd, localStartCueCompletedAt = cueEnd),
                ))
            }

            if (!held || requestGeneration != generation) {
                runCatching { floor.release(leaseId) }
                update(snapshot.copy(state = PttState.IDLE, leaseId = null, currentSpeaker = null))
                return
            }

            val enabled = if (bufferedGenerationId != null) {
                runCatching { bufferedAudio?.authorize(leaseId, bufferedGenerationId) == true }.getOrDefault(false)
            } else {
                runCatching { microphone.setEnabled(true) }.getOrDefault(false)
            }
            if (!enabled) {
                held = false
                runCatching { floor.release(leaseId) }
                bufferedGenerationId?.let { bufferedAudio?.discard(it) }
                activeBufferedGenerationId = null
                update(snapshot.copy(state = PttState.ERROR, leaseId = null, lastError = "Audio TX could not start"))
                playStatusCue("ERROR", cuePlayer.playError())
                return
            }

            val trackEnabledAt = clock.now()
            update(
                snapshot.copy(
                    state = PttState.TRANSMITTING,
                    leaseId = leaseId,
                    timing = snapshot.timing.copy(
                        trackEnabledAt = trackEnabledAt,
                        localEnableLatencyMs = clock.elapsedRealtimeMs() - downMark,
                    ),
                ),
            )
        }
    }

    suspend fun pressUp() {
        held = false
        generation += 1
        control.cancelRxReady()
        transitionMutex.withLock {
            val leaseId = snapshot.leaseId
            cancelTimers()
            if (snapshot.state == PttState.TRANSMITTING) {
                val generationId = activeBufferedGenerationId
                if (generationId != null && bufferedAudio?.beginReleaseHangover(generationId) != true) {
                    return@withLock
                }
                val muted = if (generationId != null) {
                    if (withTimeoutOrNull(TX_RELEASE_HANG_MS) { safetyStopSignal.receive() } != null) {
                        return@withLock
                    }
                    if (bufferedAudio?.completeReleaseHangover(generationId) != true) return@withLock
                    runCatching { bufferedAudio?.finish(generationId) == true }.getOrDefault(false)
                } else {
                    if (withTimeoutOrNull(TX_RELEASE_HANG_MS) { safetyStopSignal.receive() } != null) {
                        return@withLock
                    }
                    runCatching { microphone.setEnabled(false) }.getOrDefault(false)
                }
                activeBufferedGenerationId = null
                if (muted && leaseId != null) {
                    if (withTimeoutOrNull(TX_POST_MUTE_FLUSH_MS) { safetyStopSignal.receive() } != null) {
                        return@withLock
                    }
                    val controlResult = control.publishEnd(leaseId)
                    update(snapshot.copy(controlEndResult = controlResult.fold(
                        { "Sent" },
                        { "Failed: ${it.message ?: "unknown"}" },
                    )))
                    playEndCue()
                } else if (!muted) {
                    update(snapshot.copy(endCueResult = "Skipped: TX OFF failed"))
                }
                if (leaseId != null) runCatching { floor.release(leaseId) }
                update(
                    snapshot.copy(
                        state = if (muted) PttState.IDLE else PttState.ERROR,
                        leaseId = null,
                        currentSpeaker = null,
                        lastError = if (muted) null else "Microphone TX stop failed; Room was disconnected",
                    ),
                )
            } else if (leaseId != null) {
                runCatching { floor.release(leaseId) }
                update(snapshot.copy(state = PttState.IDLE, leaseId = null, currentSpeaker = null))
            } else if (snapshot.state == PttState.BUSY) {
                update(snapshot.copy(state = PttState.IDLE, currentSpeaker = null))
            }
        }
    }

    suspend fun stopForSafety(reason: String) {
        held = false
        generation += 1
        safetyStopSignal.trySend(Unit)
        control.cancelRxReady()
        transitionMutex.withLock {
            val leaseId = snapshot.leaseId
            cancelTimers()
            discardActiveBuffered()
            val muted = runCatching { microphone.setEnabled(false) }.getOrDefault(false)
            val release = leaseId?.let { scope.launch { runCatching { floor.release(it) } } }
            if (leaseId != null && muted) {
                val controlResult = control.publishEnd(leaseId)
                update(snapshot.copy(controlEndResult = controlResult.fold(
                    { "Sent" },
                    { "Failed: ${it.message ?: "unknown"}" },
                )))
            }
            release?.join()
            update(snapshot.copy(state = PttState.ERROR, leaseId = null, lastError = reason))
            playStatusCue("ERROR", cuePlayer.playError())
        }
    }

    private fun startRenewal(leaseId: String, expectedGeneration: Long) {
        renewJob?.cancel()
        renewJob = scope.launch {
            while (true) {
                delay(FLOOR_RENEW_INTERVAL_MS)
                if (!held || generation != expectedGeneration || snapshot.leaseId != leaseId) return@launch
                val renewed = runCatching { floor.renew(leaseId) }
                if (renewed.isFailure || renewed.getOrNull()?.outcome != "renewed") {
                    scope.launch { failLease("Floor lease renewal failed", leaseId, expectedGeneration) }
                    return@launch
                }
            }
        }
    }

    private fun startMaxTxGuard(leaseId: String, expectedGeneration: Long, maxTxExpiresAt: String?) {
        maxTxJob?.cancel()
        val remaining = maxTxExpiresAt
            ?.let { runCatching { Instant.parse(it).toEpochMilli() - clock.now().toEpochMilli() }.getOrNull() }
            ?.coerceIn(0L, MAX_CONTINUOUS_TX_MS)
            ?: MAX_CONTINUOUS_TX_MS
        maxTxJob = scope.launch {
            delay(remaining)
            if (generation != expectedGeneration || snapshot.leaseId != leaseId) return@launch
            scope.launch { finishMaxTx(leaseId, expectedGeneration) }
        }
    }

    private suspend fun finishMaxTx(leaseId: String, expectedGeneration: Long) {
        safetyStopSignal.trySend(Unit)
        transitionMutex.withLock {
            if (generation != expectedGeneration || snapshot.leaseId != leaseId) return
            held = false
            generation += 1
            control.cancelRxReady()
            cancelTimers()
            val bufferedGeneration = activeBufferedGenerationId
            val muted = if (bufferedGeneration != null) {
                runCatching { bufferedAudio?.finish(bufferedGeneration) == true }.getOrDefault(false)
            } else {
                runCatching { microphone.setEnabled(false) }.getOrDefault(false)
            }
            activeBufferedGenerationId = null
            update(
                snapshot.copy(
                    state = if (muted) PttState.IDLE else PttState.ERROR,
                    leaseId = null,
                    currentSpeaker = null,
                    lastError = if (muted) null else "Microphone TX stop failed; Room was disconnected",
                ),
            )
            val release = scope.launch { runCatching { floor.release(leaseId) } }
            if (muted) {
                val controlResult = control.publishEnd(leaseId)
                update(snapshot.copy(controlEndResult = controlResult.fold(
                    { "Sent" },
                    { "Failed: ${it.message ?: "unknown"}" },
                )))
                playEndCue()
            } else {
                update(snapshot.copy(endCueResult = "Skipped: TX OFF failed"))
            }
            release.join()
        }
    }

    private suspend fun failLease(reason: String, leaseId: String, expectedGeneration: Long) {
        safetyStopSignal.trySend(Unit)
        transitionMutex.withLock {
            if (generation != expectedGeneration || snapshot.leaseId != leaseId) return
            held = false
            generation += 1
            control.cancelRxReady()
            cancelTimers()
            discardActiveBuffered()
            val muted = runCatching { microphone.setEnabled(false) }.getOrDefault(false)
            update(snapshot.copy(state = PttState.ERROR, leaseId = null, lastError = reason))
            playStatusCue("ERROR", cuePlayer.playError())
            val release = scope.launch { runCatching { floor.release(leaseId) } }
            if (muted) {
                val controlResult = control.publishEnd(leaseId)
                update(snapshot.copy(controlEndResult = controlResult.fold(
                    { "Sent" },
                    { "Failed: ${it.message ?: "unknown"}" },
                )))
            }
            release.join()
        }
    }

    private suspend fun playEndCue() {
        val result = cuePlayer.playEnd()
        update(snapshot.copy(endCueResult = result.fold({ "Played" }, { "Failed: ${it.message ?: "unknown"}" })))
    }

    private fun playStatusCue(type: String, result: Result<Unit>) {
        update(snapshot.copy(statusCueResult = result.fold(
            { "$type played" },
            { "$type failed: ${it.message ?: "unknown"}" },
        )))
    }

    private fun cancelTimers() {
        renewJob?.cancel()
        renewJob = null
        maxTxJob?.cancel()
        maxTxJob = null
    }

    private fun discardActiveBuffered() {
        activeBufferedGenerationId?.let { bufferedAudio?.discard(it) }
        activeBufferedGenerationId = null
    }

    private fun update(value: PttSnapshot) {
        snapshot = value
        onSnapshot(value)
    }
}
