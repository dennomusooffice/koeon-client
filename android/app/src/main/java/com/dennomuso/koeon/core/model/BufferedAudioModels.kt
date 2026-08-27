package com.dennomuso.koeon.core.model

import kotlinx.serialization.Serializable

@Serializable data class Batv1Chunk(val sequence: Int, val payloadBase64: String)

@Serializable
data class Batv1PublishRequest(
    val protocolVersion: Int = 1,
    val generationId: String,
    val channelId: String,
    val speakerSessionId: String,
    val speakerDeviceId: String,
    val leaseId: String,
    val codec: String = "pcm16le",
    val sampleRate: Int = 48_000,
    val channels: Int = 1,
    val frameDurationMs: Int = 20,
    val sessionId: String,
    val chunks: List<Batv1Chunk>,
    val finalSequence: Int? = null,
)

@Serializable data class Batv1PublishResponse(val outcome: String, val acceptedChunks: Int, val latestSequence: Int)
@Serializable data class Batv1SubscribeRequest(val sessionId: String, val generationId: String, val nextSequence: Int)
@Serializable
data class Batv1SubscribeResponse(
    val generationId: String,
    val latestSequence: Int,
    val nextSequence: Int,
    val finalSequence: Int? = null,
    val bufferHeadExpired: Boolean,
    val timelineEnded: Boolean,
    val chunks: List<Batv1Chunk>,
)
