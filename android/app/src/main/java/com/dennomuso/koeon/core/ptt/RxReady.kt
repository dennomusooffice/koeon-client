package com.dennomuso.koeon.core.ptt

import android.os.SystemClock
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

const val PTT_RX_READY_TOPIC = "koeon.ptt.rx-ready.v1"
const val PTT_RX_READY_VERSION = 1
const val RX_READY_SINGLE_MAX_WAIT_MS = 4_000L
const val RX_READY_MULTI_ABSOLUTE_MAX_MS = 4_000L

@Serializable
data class PttRxReadyEvent(
    val version: Int = PTT_RX_READY_VERSION,
    val type: String = "rx_ready",
    val channelId: String,
    val speakerSessionId: String,
    val receiverSessionId: String,
    val receiverDeviceId: String? = null,
    val leaseId: String,
    val readyAt: Long,
)

enum class RxReadyReason {
    NO_EXPECTATIONS,
    ALL_READY,
    SINGLE_TIMEOUT,
    MULTI_TIMEOUT,
    CANCELLED,
}

data class RxReadyResult(
    val reason: RxReadyReason,
    val expectedCount: Int,
    val receivedCountAtMicOn: Int,
    val ratioAtMicOn: Double,
    val lateCount: Int,
    val waitMs: Long,
    val firstReadyAtMs: Long? = null,
    val allReadyAtMs: Long? = null,
) {
    val timedOut: Boolean
        get() = reason == RxReadyReason.SINGLE_TIMEOUT || reason == RxReadyReason.MULTI_TIMEOUT
}

enum class RxReadyAcceptance {
    ACCEPTED,
    PENDING_PARTICIPANT_METADATA,
    REJECTED_SESSION_MISMATCH,
    REJECTED_DEVICE_MISMATCH,
    REJECTED_LEASE_MISMATCH,
    REJECTED_CHANNEL_MISMATCH,
    REJECTED_DUPLICATE,
    REJECTED_DEADLINE_EXPIRED,
    REJECTED_MALFORMED,
}

enum class RxReadyReconcileSource {
    PARTICIPANT_CONNECTED,
    PARTICIPANT_METADATA_CHANGED,
    BOUNDED_POLL,
}

data class RxReadyAuditSnapshot(
    val receivedEvents: Int = 0,
    val rejectedEvents: Int = 0,
    val rejectedSessionMismatch: Int = 0,
    val rejectedDeviceMismatch: Int = 0,
    val rejectedParticipantMetadataMissing: Int = 0,
    val rejectedLeaseMismatch: Int = 0,
    val rejectedChannelMismatch: Int = 0,
    val rejectedDuplicate: Int = 0,
    val rejectedDeadlineExpired: Int = 0,
    val pendingMetadataCount: Int = 0,
    val pendingMetadataEvents: Int = 0,
    val pendingOldestAgeMs: Long? = null,
    val pendingMaximumObservedAgeMs: Long = 0,
    val barrierStartedAtElapsedRealtimeMs: Long = 0,
    val barrierDeadlineAtElapsedRealtimeMs: Long = 0,
    val metadataAvailableAtMs: Long? = null,
    val lastReconcileSource: RxReadyReconcileSource? = null,
    val completionReason: RxReadyReason? = null,
    val firstEventReceivedAtMs: Long? = null,
    val firstAcceptedAtMs: Long? = null,
)

class RxReadyBarrier(
    expectedSessionIds: List<String>,
    expectedDeviceIds: List<String> = emptyList(),
    private val channelId: String,
    private val speakerSessionId: String,
    private val leaseId: String,
    private val elapsedRealtimeMs: () -> Long = SystemClock::elapsedRealtime,
    private val wallClockMs: () -> Long = System::currentTimeMillis,
) {
    private data class PendingReady(val event: PttRxReadyEvent, val receivedAtElapsedRealtimeMs: Long)

    private val expected = expectedSessionIds.filter(String::isNotBlank).toSet()
    private val expectedDevices = expectedDeviceIds.filter(String::isNotBlank).toSet()
    private val effectiveExpected = if (expectedDevices.isEmpty()) expected else expectedDevices
    private val received = mutableSetOf<String>()
    private val signal = Channel<Unit>(Channel.CONFLATED)
    private val startedAt = elapsedRealtimeMs()
    private val deadlineAt = startedAt + if (effectiveExpected.size <= 1) {
        RX_READY_SINGLE_MAX_WAIT_MS
    } else {
        RX_READY_MULTI_ABSOLUTE_MAX_MS
    }
    private var cancelled = false
    private var completedAtMicOn: Int? = null
    private var firstReadyAt: Long? = null
    private var allReadyAt: Long? = null
    private val pendingBySession = mutableMapOf<String, PendingReady>()
    private var audit = RxReadyAuditSnapshot(
        barrierStartedAtElapsedRealtimeMs = startedAt,
        barrierDeadlineAtElapsedRealtimeMs = deadlineAt,
    )

    fun accept(event: PttRxReadyEvent, participantIdentity: String?, participantDeviceId: String? = null): Boolean =
        acceptDetailed(event, participantIdentity, participantDeviceId) == RxReadyAcceptance.ACCEPTED

    fun acceptDetailed(
        event: PttRxReadyEvent,
        participantIdentity: String?,
        participantDeviceId: String? = null,
    ): RxReadyAcceptance = synchronized(this) {
        val eventAtElapsed = elapsedRealtimeMs()
        val eventAt = wallClockMs()
        audit = audit.copy(
            receivedEvents = audit.receivedEvents + 1,
            firstEventReceivedAtMs = audit.firstEventReceivedAtMs ?: eventAt,
        )
        if (cancelled || event.version != PTT_RX_READY_VERSION || event.type != "rx_ready") {
            return@synchronized reject(RxReadyAcceptance.REJECTED_MALFORMED)
        }
        if (eventAtElapsed >= deadlineAt) {
            return@synchronized reject(RxReadyAcceptance.REJECTED_DEADLINE_EXPIRED)
        }
        if (event.channelId != channelId) return@synchronized reject(RxReadyAcceptance.REJECTED_CHANNEL_MISMATCH)
        if (event.leaseId != leaseId) return@synchronized reject(RxReadyAcceptance.REJECTED_LEASE_MISMATCH)
        if (participantIdentity.isNullOrBlank() || event.speakerSessionId != speakerSessionId ||
            event.receiverSessionId != participantIdentity
        ) return@synchronized reject(RxReadyAcceptance.REJECTED_SESSION_MISMATCH)

        val readyIdentity = if (expectedDevices.isNotEmpty()) {
            val eventDevice = event.receiverDeviceId
            if (eventDevice.isNullOrBlank() || eventDevice !in expectedDevices) {
                return@synchronized reject(RxReadyAcceptance.REJECTED_DEVICE_MISMATCH)
            }
            if (participantDeviceId.isNullOrBlank()) {
                if (received.contains(eventDevice)) return@synchronized reject(RxReadyAcceptance.REJECTED_DUPLICATE)
                pendingBySession[participantIdentity] = PendingReady(event, eventAtElapsed)
                audit = audit.copy(
                    rejectedParticipantMetadataMissing = audit.rejectedParticipantMetadataMissing + 1,
                    pendingMetadataEvents = audit.pendingMetadataEvents + 1,
                    pendingMetadataCount = pendingBySession.size,
                )
                refreshPendingAudit(eventAtElapsed)
                return@synchronized RxReadyAcceptance.PENDING_PARTICIPANT_METADATA
            }
            if (eventDevice != participantDeviceId) {
                return@synchronized reject(RxReadyAcceptance.REJECTED_DEVICE_MISMATCH)
            }
            eventDevice
        } else {
            if (participantIdentity !in expected) return@synchronized reject(RxReadyAcceptance.REJECTED_SESSION_MISMATCH)
            participantIdentity
        }
        acceptIdentity(readyIdentity, eventAt)
    }

    fun reconcileParticipant(
        participantIdentity: String?,
        participantDeviceId: String?,
        source: RxReadyReconcileSource = RxReadyReconcileSource.PARTICIPANT_METADATA_CHANGED,
    ): Boolean = synchronized(this) {
        if (cancelled || participantIdentity.isNullOrBlank() || participantDeviceId.isNullOrBlank()) return@synchronized false
        val pending = pendingBySession[participantIdentity] ?: return@synchronized false
        val nowElapsed = elapsedRealtimeMs()
        if (nowElapsed >= deadlineAt) {
            pendingBySession.remove(participantIdentity)
            refreshPendingAudit(nowElapsed)
            reject(RxReadyAcceptance.REJECTED_DEADLINE_EXPIRED)
            return@synchronized false
        }
        val eventDevice = pending.event.receiverDeviceId
        if (eventDevice != participantDeviceId || eventDevice !in expectedDevices) {
            pendingBySession.remove(participantIdentity)
            refreshPendingAudit(nowElapsed)
            reject(RxReadyAcceptance.REJECTED_DEVICE_MISMATCH)
            return@synchronized false
        }
        pendingBySession.remove(participantIdentity)
        audit = audit.copy(
            metadataAvailableAtMs = wallClockMs(),
            lastReconcileSource = source,
        )
        refreshPendingAudit(nowElapsed)
        acceptIdentity(eventDevice, wallClockMs()) == RxReadyAcceptance.ACCEPTED
    }

    fun auditSnapshot(): RxReadyAuditSnapshot = synchronized(this) {
        refreshPendingAudit(elapsedRealtimeMs())
        audit
    }

    fun hasPendingMetadata(): Boolean = synchronized(this) { pendingBySession.isNotEmpty() && !cancelled }

    fun remainingMs(): Long = synchronized(this) { (deadlineAt - elapsedRealtimeMs()).coerceAtLeast(0L) }

    fun discardPendingParticipant(participantIdentity: String?) = synchronized(this) {
        participantIdentity?.let(pendingBySession::remove)
        refreshPendingAudit(elapsedRealtimeMs())
    }

    fun expirePendingAtDeadline() = synchronized(this) {
        if (elapsedRealtimeMs() < deadlineAt) return@synchronized
        val expired = pendingBySession.size
        pendingBySession.clear()
        repeat(expired) { reject(RxReadyAcceptance.REJECTED_DEADLINE_EXPIRED) }
        refreshPendingAudit(elapsedRealtimeMs())
    }

    private fun acceptIdentity(readyIdentity: String, now: Long): RxReadyAcceptance {
        if (!received.add(readyIdentity)) return reject(RxReadyAcceptance.REJECTED_DUPLICATE)
        if (firstReadyAt == null) firstReadyAt = now
        if (received.size == effectiveExpected.size) allReadyAt = now
        audit = audit.copy(firstAcceptedAtMs = audit.firstAcceptedAtMs ?: now)
        signal.trySend(Unit)
        return RxReadyAcceptance.ACCEPTED
    }

    private fun reject(reason: RxReadyAcceptance): RxReadyAcceptance {
        audit = audit.copy(
            rejectedEvents = audit.rejectedEvents + 1,
            rejectedSessionMismatch = audit.rejectedSessionMismatch + if (reason == RxReadyAcceptance.REJECTED_SESSION_MISMATCH) 1 else 0,
            rejectedDeviceMismatch = audit.rejectedDeviceMismatch + if (reason == RxReadyAcceptance.REJECTED_DEVICE_MISMATCH) 1 else 0,
            rejectedLeaseMismatch = audit.rejectedLeaseMismatch + if (reason == RxReadyAcceptance.REJECTED_LEASE_MISMATCH) 1 else 0,
            rejectedChannelMismatch = audit.rejectedChannelMismatch + if (reason == RxReadyAcceptance.REJECTED_CHANNEL_MISMATCH) 1 else 0,
            rejectedDuplicate = audit.rejectedDuplicate + if (reason == RxReadyAcceptance.REJECTED_DUPLICATE) 1 else 0,
            rejectedDeadlineExpired = audit.rejectedDeadlineExpired + if (reason == RxReadyAcceptance.REJECTED_DEADLINE_EXPIRED) 1 else 0,
        )
        return reason
    }

    private fun refreshPendingAudit(nowElapsed: Long) {
        val ages = pendingBySession.values.map {
            (nowElapsed - it.receivedAtElapsedRealtimeMs).coerceAtLeast(0L)
        }
        audit = audit.copy(
            pendingMetadataCount = pendingBySession.size,
            pendingOldestAgeMs = ages.maxOrNull(),
            pendingMaximumObservedAgeMs = maxOf(audit.pendingMaximumObservedAgeMs, ages.maxOrNull() ?: 0L),
        )
    }

    fun cancel() = synchronized(this) {
        if (!cancelled) {
            cancelled = true
            pendingBySession.clear()
            audit = audit.copy(pendingMetadataCount = 0)
            signal.trySend(Unit)
        }
    }

    suspend fun waitForReady(): RxReadyResult {
        if (effectiveExpected.isEmpty()) return finish(RxReadyReason.NO_EXPECTATIONS, waitMs = 0)
        if (effectiveExpected.size == 1) {
            val remaining = remainingMs()
            if (remaining <= 0L) return finish(RxReadyReason.SINGLE_TIMEOUT)
            val woke = withTimeoutOrNull(remaining) {
                while (true) {
                    if (isCancelled() || isAllReady()) break
                    signal.receive()
                }
                true
            } ?: false
            return when {
                isCancelled() -> finish(RxReadyReason.CANCELLED)
                isAllReady() -> finish(RxReadyReason.ALL_READY)
                !woke -> finish(RxReadyReason.SINGLE_TIMEOUT)
                else -> finish(RxReadyReason.SINGLE_TIMEOUT)
            }
        }

        while (!isCancelled() && !isAllReady()) {
            val remaining = deadlineAt - elapsedRealtimeMs()
            if (remaining <= 0) return finish(RxReadyReason.MULTI_TIMEOUT)
            if (withTimeoutOrNull(remaining) { signal.receive() } == null) {
                return finish(RxReadyReason.MULTI_TIMEOUT)
            }
        }
        return when {
            isCancelled() -> finish(RxReadyReason.CANCELLED)
            isAllReady() -> finish(RxReadyReason.ALL_READY)
            else -> finish(RxReadyReason.MULTI_TIMEOUT)
        }
    }

    fun lateCount(): Int = synchronized(this) {
        (received.size - (completedAtMicOn ?: received.size)).coerceAtLeast(0)
    }

    fun expectedCount(): Int = effectiveExpected.size

    fun receivedCount(): Int = synchronized(this) { received.size }

    private fun finish(reason: RxReadyReason, waitMs: Long? = null): RxReadyResult = synchronized(this) {
        if (reason == RxReadyReason.SINGLE_TIMEOUT || reason == RxReadyReason.MULTI_TIMEOUT) {
            expirePendingAtDeadline()
        }
        audit = audit.copy(completionReason = reason)
        val count = received.size
        completedAtMicOn = count
        RxReadyResult(
            reason = reason,
            expectedCount = effectiveExpected.size,
            receivedCountAtMicOn = count,
            ratioAtMicOn = if (effectiveExpected.isEmpty()) 1.0 else count.toDouble() / effectiveExpected.size,
            lateCount = lateCount(),
            waitMs = waitMs ?: (elapsedRealtimeMs() - startedAt).coerceAtLeast(0L),
            firstReadyAtMs = firstReadyAt,
            allReadyAtMs = allReadyAt,
        )
    }

    private fun isCancelled(): Boolean = synchronized(this) { cancelled }
    private fun isAllReady(): Boolean = synchronized(this) { received.size == effectiveExpected.size }
}

internal val pttRxReadyJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}
