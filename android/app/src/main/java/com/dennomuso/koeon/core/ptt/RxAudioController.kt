package com.dennomuso.koeon.core.ptt

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import com.dennomuso.koeon.core.model.FloorResponse

const val RX_DRAIN_MIN_MS = 120L
const val RX_SILENCE_CONFIRM_MS = 60L
const val RX_DRAIN_MAX_MS = 350L

enum class RxState { RX_IDLE, RX_STARTING, RX_ACTIVE, RX_DRAINING }

data class RxSnapshot(
    val state: RxState = RxState.RX_IDLE,
    val speakerUserId: String? = null,
    val sessionId: String? = null,
    val leaseId: String? = null,
    val rxStartedAt: Instant? = null,
    val rxEndSignalAt: Instant? = null,
    val rxDrainStartedAt: Instant? = null,
    val rxDrainCompletedAt: Instant? = null,
    val rxDrainDurationMs: Long? = null,
    val rxEndReason: String? = null,
    val controlEventType: String? = null,
    val controlSequence: Long? = null,
    val controlEventLate: Boolean = false,
    val controlEventFallback: Boolean = false,
    val duplicateIgnored: Int = 0,
    val staleIgnored: Int = 0,
    val preempted: Int = 0,
    val startCueResult: String = "Not played",
    val endCueResult: String = "Not played",
)

interface RxClock {
    fun nowMillis(): Long
    fun now(): Instant = Instant.ofEpochMilli(nowMillis())
    suspend fun sleep(milliseconds: Long)
}

class SystemRxClock : RxClock {
    override fun nowMillis(): Long = System.currentTimeMillis()
    override suspend fun sleep(milliseconds: Long) = delay(milliseconds)
}

class RxAudioController(
    private val scope: CoroutineScope,
    private val channelId: String,
    private val cuePlayer: PttCuePlayer,
    private val clock: RxClock = SystemRxClock(),
    private val onSnapshot: (RxSnapshot) -> Unit,
) {
    private var snapshot = RxSnapshot()
    private val lastSequenceBySession = mutableMapOf<String, Long>()
    private var generation = 0L
    private var audioActive = false
    private var pendingActiveSessionId: String? = null
    private var silenceStartedAt: Long? = null
    private var drainCheckJob: Job? = null
    private var hardCapJob: Job? = null

    fun current(): RxSnapshot = snapshot

    /** Returns true only when a new, validated START has armed an RX generation. */
    fun handleControl(event: PttControlEvent, senderSessionId: String?): Boolean {
        if (
            event.version != PTT_CONTROL_VERSION ||
            event.channelId != channelId ||
            event.type !in setOf("start", "end") ||
            event.sequence < 0 ||
            (event.type == "start" && senderSessionId == null) ||
            (senderSessionId != null && senderSessionId != event.sessionId)
        ) {
            update(snapshot.copy(staleIgnored = snapshot.staleIgnored + 1))
            return false
        }
        val last = lastSequenceBySession[event.sessionId]
        if (last != null && event.sequence <= last) {
            update(if (event.sequence == last) {
                snapshot.copy(duplicateIgnored = snapshot.duplicateIgnored + 1)
            } else {
                snapshot.copy(staleIgnored = snapshot.staleIgnored + 1)
            })
            return false
        }
        lastSequenceBySession[event.sessionId] = event.sequence
        if (event.type == "start") {
            start(event)
            return true
        }
        end(event)
        return false
    }

    fun handleRemoteAudioActivity(senderSessionId: String?, active: Boolean) {
        if (snapshot.sessionId == null) {
            audioActive = active
            pendingActiveSessionId = if (active) senderSessionId else null
            if (active) update(snapshot.copy(controlEventFallback = true))
            return
        }
        if (senderSessionId != null && senderSessionId != snapshot.sessionId) {
            if (active) pendingActiveSessionId = senderSessionId
            return
        }
        audioActive = active
        if (active) {
            silenceStartedAt = null
            if (snapshot.state == RxState.RX_STARTING) update(snapshot.copy(state = RxState.RX_ACTIVE))
        } else {
            silenceStartedAt = clock.nowMillis()
            if (snapshot.state == RxState.RX_DRAINING) scheduleDrainCheck()
        }
    }

    /** Reconciles a missed END against Backend Floor truth without bypassing drain safety. */
    fun reconcileFloor(floor: FloorResponse) {
        val sessionId = snapshot.sessionId ?: return
        val leaseId = snapshot.leaseId ?: return
        if (snapshot.state == RxState.RX_IDLE || snapshot.state == RxState.RX_DRAINING) return
        if (floor.outcome != "available" && floor.leaseId == leaseId) return
        beginDrain(
            reason = if (floor.outcome == "available") "floor_available" else "floor_lease_changed",
            sessionId = sessionId,
            leaseId = leaseId,
        )
    }

    fun reset() {
        generation += 1
        cancelTimers()
        audioActive = false
        pendingActiveSessionId = null
        silenceStartedAt = null
        lastSequenceBySession.clear()
        update(RxSnapshot())
    }

    private fun start(event: PttControlEvent) {
        val now = clock.nowMillis()
        val old = snapshot
        val preempted = old.state == RxState.RX_DRAINING
        val voiceAlreadyActive = pendingActiveSessionId == event.sessionId ||
            (audioActive && pendingActiveSessionId == null)
        generation += 1
        val operation = generation
        cancelTimers()
        audioActive = voiceAlreadyActive
        pendingActiveSessionId = null
        silenceStartedAt = null
        update(
            snapshot.copy(
                state = if (voiceAlreadyActive) RxState.RX_ACTIVE else RxState.RX_STARTING,
                speakerUserId = event.speakerUserId,
                sessionId = event.sessionId,
                leaseId = event.leaseId,
                rxStartedAt = clock.now(),
                rxEndSignalAt = null,
                rxDrainStartedAt = null,
                rxDrainCompletedAt = if (preempted) clock.now() else null,
                rxDrainDurationMs = if (preempted) {
                    (now - (old.rxDrainStartedAt?.toEpochMilli() ?: now)).coerceAtLeast(0)
                } else null,
                rxEndReason = if (preempted) "preempted" else null,
                controlEventType = "start",
                controlSequence = event.sequence,
                controlEventLate = now - event.sentAt > RX_DRAIN_MAX_MS,
                preempted = snapshot.preempted + if (preempted) 1 else 0,
                controlEventFallback = snapshot.controlEventFallback || voiceAlreadyActive,
                startCueResult = if (voiceAlreadyActive) "Skipped: voice already active" else "Playing",
                endCueResult = "Not played",
            ),
        )
        if (voiceAlreadyActive) return
        scope.launch {
            val result = cuePlayer.playStart()
            if (operation != generation) return@launch
            update(snapshot.copy(
                state = RxState.RX_ACTIVE,
                startCueResult = result.fold({ "Played" }, { "Failed: ${it.message ?: "unknown"}" }),
            ))
        }
    }

    private fun end(event: PttControlEvent) {
        if (
            snapshot.sessionId != event.sessionId ||
            snapshot.leaseId != event.leaseId ||
            snapshot.speakerUserId != event.speakerUserId ||
            snapshot.state == RxState.RX_IDLE
        ) {
            update(snapshot.copy(staleIgnored = snapshot.staleIgnored + 1))
            return
        }
        if (snapshot.state == RxState.RX_DRAINING) {
            update(snapshot.copy(duplicateIgnored = snapshot.duplicateIgnored + 1))
            return
        }
        beginDrain("control_end", event.sessionId, event.leaseId, event)
    }

    private fun beginDrain(
        reason: String,
        sessionId: String,
        leaseId: String,
        event: PttControlEvent? = null,
    ) {
        if (snapshot.sessionId != sessionId || snapshot.leaseId != leaseId || snapshot.state == RxState.RX_IDLE) return
        if (snapshot.state == RxState.RX_DRAINING) return
        generation += 1
        cancelTimers()
        val now = clock.nowMillis()
        if (!audioActive) silenceStartedAt = now
        update(snapshot.copy(
            state = RxState.RX_DRAINING,
            rxEndSignalAt = clock.now(),
            rxDrainStartedAt = clock.now(),
            rxEndReason = reason,
            controlEventType = event?.let { "end" } ?: snapshot.controlEventType,
            controlSequence = event?.sequence ?: snapshot.controlSequence,
            controlEventLate = event?.let { now - it.sentAt > RX_DRAIN_MAX_MS } ?: snapshot.controlEventLate,
        ))
        hardCapJob = scope.launch {
            clock.sleep(RX_DRAIN_MAX_MS)
            scope.launch { completeDrain("hard_cap") }
        }
        scheduleDrainCheck()
    }

    private fun scheduleDrainCheck() {
        if (snapshot.state != RxState.RX_DRAINING) return
        drainCheckJob?.cancel()
        val now = clock.nowMillis()
        val elapsed = now - (snapshot.rxDrainStartedAt?.toEpochMilli() ?: now)
        val minimumRemaining = (RX_DRAIN_MIN_MS - elapsed).coerceAtLeast(0)
        val silentFor = silenceStartedAt?.let { now - it } ?: 0
        val silenceRemaining = if (audioActive || silenceStartedAt == null) {
            RX_DRAIN_MAX_MS
        } else {
            (RX_SILENCE_CONFIRM_MS - silentFor).coerceAtLeast(0)
        }
        drainCheckJob = scope.launch {
            clock.sleep(maxOf(minimumRemaining, silenceRemaining))
            val checkedAt = clock.nowMillis()
            val drainElapsed = checkedAt - (snapshot.rxDrainStartedAt?.toEpochMilli() ?: checkedAt)
            val confirmedSilence = silenceStartedAt?.let { checkedAt - it } ?: 0
            if (!audioActive && drainElapsed >= RX_DRAIN_MIN_MS && confirmedSilence >= RX_SILENCE_CONFIRM_MS) {
                scope.launch { completeDrain("silence") }
            }
        }
    }

    private suspend fun completeDrain(reason: String) {
        if (snapshot.state != RxState.RX_DRAINING) return
        generation += 1
        val operation = generation
        cancelTimers()
        val now = clock.nowMillis()
        update(snapshot.copy(
            rxDrainCompletedAt = clock.now(),
            rxDrainDurationMs = (now - (snapshot.rxDrainStartedAt?.toEpochMilli() ?: now))
                .coerceIn(0, RX_DRAIN_MAX_MS),
            rxEndReason = reason,
            endCueResult = "Playing",
        ))
        val result = cuePlayer.playEnd()
        if (operation != generation) return
        update(snapshot.copy(
            state = RxState.RX_IDLE,
            speakerUserId = null,
            sessionId = null,
            leaseId = null,
            endCueResult = result.fold({ "Played" }, { "Failed: ${it.message ?: "unknown"}" }),
        ))
    }

    private fun cancelTimers() {
        drainCheckJob?.cancel()
        hardCapJob?.cancel()
        drainCheckJob = null
        hardCapJob = null
    }

    private fun update(next: RxSnapshot) {
        snapshot = next
        onSnapshot(next)
    }
}
