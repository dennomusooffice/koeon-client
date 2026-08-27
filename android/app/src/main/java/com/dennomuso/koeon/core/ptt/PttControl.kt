package com.dennomuso.koeon.core.ptt

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

const val PTT_CONTROL_TOPIC = "koeon.ptt.control"
const val PTT_CONTROL_FAST_START_TOPIC = "koeon.ptt.control.fast-start.v1"
const val PTT_CONTROL_VERSION = 1

@Serializable
data class PttControlEvent(
    val version: Int = PTT_CONTROL_VERSION,
    val type: String,
    val channelId: String,
    val speakerUserId: String,
    val sessionId: String,
    val leaseId: String,
    val sequence: Long,
    val sentAt: Long,
    val bufferedGenerationId: String? = null,
)

interface PttControlGateway {
    fun prepareRxReady(leaseId: String, expectedSessionIds: List<String>) = Unit
    fun prepareRxReady(leaseId: String, expectedSessionIds: List<String>, expectedDeviceIds: List<String>) =
        prepareRxReady(leaseId, expectedSessionIds)
    suspend fun publishStart(leaseId: String): Result<Unit>
    suspend fun publishBufferedStart(leaseId: String, generationId: String): Result<Unit> = publishStart(leaseId)
    suspend fun awaitRxReady(leaseId: String): RxReadyResult = RxReadyResult(
        reason = RxReadyReason.NO_EXPECTATIONS,
        expectedCount = 0,
        receivedCountAtMicOn = 0,
        ratioAtMicOn = 1.0,
        lateCount = 0,
        waitMs = 0,
    )
    suspend fun publishEnd(leaseId: String): Result<Unit>
    fun cancelRxReady() = Unit
}

object NoopPttControlGateway : PttControlGateway {
    override suspend fun publishStart(leaseId: String): Result<Unit> = Result.success(Unit)
    override suspend fun publishEnd(leaseId: String): Result<Unit> = Result.success(Unit)
}

internal val pttControlJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}
