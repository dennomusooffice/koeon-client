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

class RxReadyBarrier(
    expectedSessionIds: List<String>,
    expectedDeviceIds: List<String> = emptyList(),
    private val channelId: String,
    private val speakerSessionId: String,
    private val leaseId: String,
    private val elapsedRealtimeMs: () -> Long = SystemClock::elapsedRealtime,
    private val wallClockMs: () -> Long = System::currentTimeMillis,
) {
    private val expected = expectedSessionIds.filter(String::isNotBlank).toSet()
    private val expectedDevices = expectedDeviceIds.filter(String::isNotBlank).toSet()
    private val effectiveExpected = if (expectedDevices.isEmpty()) expected else expectedDevices
    private val received = mutableSetOf<String>()
    private val signal = Channel<Unit>(Channel.CONFLATED)
    private val startedAt = elapsedRealtimeMs()
    private var cancelled = false
    private var completedAtMicOn: Int? = null
    private var firstReadyAt: Long? = null
    private var allReadyAt: Long? = null

    fun accept(event: PttRxReadyEvent, participantIdentity: String?, participantDeviceId: String? = null): Boolean = synchronized(this) {
        if (
            cancelled ||
            participantIdentity.isNullOrBlank() ||
            event.version != PTT_RX_READY_VERSION ||
            event.type != "rx_ready" ||
            event.channelId != channelId ||
            event.speakerSessionId != speakerSessionId ||
            event.leaseId != leaseId ||
            event.receiverSessionId != participantIdentity
        ) return@synchronized false
        val readyIdentity = if (expectedDevices.isNotEmpty()) {
            event.receiverDeviceId?.takeIf { it == participantDeviceId && it in expectedDevices }
        } else participantIdentity.takeIf { it in expected }
        if (readyIdentity == null || !received.add(readyIdentity)) return@synchronized false
        val now = wallClockMs()
        if (firstReadyAt == null) firstReadyAt = now
        if (received.size == effectiveExpected.size) allReadyAt = now
        signal.trySend(Unit)
        true
    }

    fun cancel() = synchronized(this) {
        if (!cancelled) {
            cancelled = true
            signal.trySend(Unit)
        }
    }

    suspend fun waitForReady(): RxReadyResult {
        if (effectiveExpected.isEmpty()) return finish(RxReadyReason.NO_EXPECTATIONS, waitMs = 0)
        if (effectiveExpected.size == 1) {
            val woke = withTimeoutOrNull(RX_READY_SINGLE_MAX_WAIT_MS) {
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

        val absoluteDeadline = startedAt + RX_READY_MULTI_ABSOLUTE_MAX_MS
        while (!isCancelled() && !isAllReady()) {
            val remaining = absoluteDeadline - elapsedRealtimeMs()
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
