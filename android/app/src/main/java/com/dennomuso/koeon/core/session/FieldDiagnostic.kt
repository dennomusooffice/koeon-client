package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.BuildConfig
import com.dennomuso.koeon.core.audio.AudioAvailabilityState
import com.dennomuso.koeon.core.livekit.IntercomConnectionState
import com.dennomuso.koeon.core.ptt.PttSemanticState
import com.dennomuso.koeon.core.ptt.PttState
import com.dennomuso.koeon.core.ptt.pttSemanticState
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import java.time.Instant

const val FIELD_DIAGNOSTIC_SCHEMA = "koeon.field-diagnostic.v2"
private val fieldDiagnosticJson = Json { prettyPrint = true }

fun buildAndroidFieldDiagnostic(state: IntercomUiState, capturedAt: String = Instant.now().toString()): String {
    val semantic = pttSemanticState(
        canPublish = state.join?.canPublish == true,
        connected = state.connectionState == IntercomConnectionState.CONNECTED,
        recovering = state.diagnostics.audioAvailabilityState == AudioAvailabilityState.RECOVERING,
        remoteTalking = state.currentSpeaker != null && state.ptt.state != PttState.TRANSMITTING,
        pttState = state.ptt.state,
    )
    val eligible = semantic == PttSemanticState.READY
    val blockReason = when {
        eligible -> null
        semantic == PttSemanticState.RX_ONLY -> "RX_ONLY"
        semantic == PttSemanticState.OFFLINE -> "OFFLINE"
        semantic == PttSemanticState.RECOVERING -> "AUDIO_RECOVERING"
        semantic == PttSemanticState.BUSY_REMOTE -> "REMOTE_BUSY"
        semantic == PttSemanticState.ERROR -> "ERROR"
        else -> "PREPARING"
    }
    fun nullable(value: String?) = value?.let(::JsonPrimitive) ?: JsonNull
    fun nullable(value: Long?) = value?.let(::JsonPrimitive) ?: JsonNull
    val d = state.diagnostics
    val rx = d.rx
    val gain = d.inputGain
    val value = buildJsonObject {
        put("schema", JsonPrimitive(FIELD_DIAGNOSTIC_SCHEMA)); put("capturedAt", JsonPrimitive(capturedAt)); put("platform", JsonPrimitive("android"))
        put("settings", buildJsonObject { put("headsetPttMode", JsonPrimitive(d.headsetPttMode.name)); put("hardwareVolumePttMode", JsonPrimitive(d.hardwareVolumePttMode.name)) })
        put("state", buildJsonObject { put("connection", JsonPrimitive(state.connectionState.name)); put("ptt", JsonPrimitive(state.ptt.state.name)); put("pttSemanticState", JsonPrimitive(semantic.name)); put("pttEligible", JsonPrimitive(eligible)); put("pttBlockReason", nullable(blockReason)); put("rx", JsonPrimitive(rx.state.name)) })
        put("timingMs", buildJsonObject { put("localUiFeedback", nullable(state.ptt.timing.localUiFeedbackLatencyMs)); put("floor", nullable(state.ptt.timing.floorLatencyMs)); put("ready", nullable(state.ptt.timing.readyWaitMs)); put("controlPublish", JsonNull) })
        put("network", buildJsonObject { put("rtt", JsonNull); put("jitter", JsonNull); put("packetLoss", JsonNull) })
        put("liveKit", buildJsonObject { put("deployment", JsonPrimitive(d.liveKitDeployment)); put("endpointHost", nullable(d.liveKitEndpointHost)); put("connectionState", JsonPrimitive(state.connectionState.name)) })
        put("txSafety", buildJsonObject { put("renewFailures", JsonNull); put("lastError", nullable(state.ptt.lastError)) })
        put("rxGeneration", buildJsonObject { put("generation", JsonNull); put("duplicate", JsonPrimitive(rx.duplicateIgnored)); put("stale", JsonPrimitive(rx.staleIgnored)); put("preempted", JsonPrimitive(rx.preempted)); put("remoteClearAt", nullable(rx.rxDrainCompletedAt?.toString())) })
        put("rxReady", buildJsonObject {
            put("rxReadyProtocolVersion", JsonPrimitive(d.rxReadyProtocolVersion))
            put("rxReadyPublishAttemptedAt", nullable(d.rxReadyPublishAttemptedAt))
            put("rxReadyPublishedAt", nullable(d.rxReadyPublishedAt))
            put("rxReadyPublishResult", JsonPrimitive(d.rxReadyPublishResult))
            put("rxReadyPublishFailureClass", nullable(d.rxReadyPublishFailureClass))
            put("rxReadyStartReceivedAt", nullable(d.rxReadyStartReceivedAt))
            put("rxReadyStartArmedAt", nullable(d.rxReadyStartArmedAt))
            put("rxReadySenderIdentityPresent", d.rxReadySenderIdentityPresent?.let(::JsonPrimitive) ?: JsonNull)
            put("rxReadyReceiverDeviceIdPresent", d.rxReadyReceiverDeviceIdPresent?.let(::JsonPrimitive) ?: JsonNull)
            put("rxReadyExpectedCount", JsonPrimitive(d.rxReadyExpectedCount))
            put("rxReadyExpectedDeviceCount", JsonPrimitive(d.rxReadyExpectedCount))
            put("rxReadyReceivedCount", JsonPrimitive(d.rxReadyReceivedCount))
            put("rxReadyReceivedEventCount", JsonPrimitive(d.rxReadyReceivedEvents))
            put("rxReadyRejectedCount", JsonPrimitive(d.rxReadyRejectedCount))
            put("rxReadyRejectedSessionMismatch", JsonPrimitive(d.rxReadyRejectedSessionMismatch))
            put("rxReadyRejectedDeviceMismatch", JsonPrimitive(d.rxReadyRejectedDeviceMismatch))
            put("rxReadyRejectedParticipantMetadataMissing", JsonPrimitive(d.rxReadyRejectedParticipantMetadataMissing))
            put("rxReadyRejectedLeaseMismatch", JsonPrimitive(d.rxReadyRejectedLeaseMismatch))
            put("rxReadyRejectedChannelMismatch", JsonPrimitive(d.rxReadyRejectedChannelMismatch))
            put("rxReadyRejectedDuplicate", JsonPrimitive(d.rxReadyRejectedDuplicate))
            put("rxReadyPendingMetadataCount", JsonPrimitive(d.rxReadyPendingMetadataCount))
            put("rxReadyFirstEventReceivedAt", nullable(d.rxReadyFirstEventReceivedAt))
            put("rxReadyFirstAcceptedAt", nullable(d.rxReadyFirstAcceptedAt))
            put("rxReadyTimeoutReason", if (state.ptt.rxReadyTimedOut) JsonPrimitive("READY_TIMEOUT") else JsonNull)
        })
        put("audio", buildJsonObject {
            put("route", nullable(d.audioRoute)); put("focus", nullable(d.audioFocus))
            put("audioBitratePreset", JsonPrimitive(d.audioBitratePreset.name))
            put("requestedAudioBitrateKbps", JsonPrimitive(d.requestedAudioBitrateKbps))
            put("effectiveAudioBitrateKbps", d.effectiveAudioBitrateKbps?.let(::JsonPrimitive) ?: JsonNull)
            put("processing", buildJsonObject {
                put("echoCancellation", JsonPrimitive("WEBRTC")); put("noiseSuppression", JsonPrimitive("WEBRTC"))
                put("profile", JsonPrimitive(d.audioCaptureProfile.name))
                put("autoGainControl", if (d.audioCaptureProfile.webRtcAgcEnabled) JsonPrimitive("WEBRTC") else JsonPrimitive("OFF")); put("highPassFilter", JsonPrimitive("WEBRTC"))
                put("typingNoiseDetection", JsonPrimitive("WEBRTC")); put("enhancedProcessor", JsonNull)
            })
        })
        put("audioGain", buildJsonObject { put("mode", JsonPrimitive(gain.mode.name)); put("effectiveDb", JsonPrimitive(gain.effectiveGainDb)); put("preKoeonRmsDbfs", gain.inputRmsDbfs?.let(::JsonPrimitive) ?: JsonNull); put("preKoeonPeakDbfs", gain.inputPeakDbfs?.let(::JsonPrimitive) ?: JsonNull); put("postKoeonRmsDbfs", gain.postKoeonRmsDbfs?.let(::JsonPrimitive) ?: JsonNull); put("postKoeonPeakDbfs", gain.postKoeonPeakDbfs?.let(::JsonPrimitive) ?: JsonNull); put("limiterHits", JsonPrimitive(gain.limiterHitCount)) })
        put("bufferedAudio", buildJsonObject {
            val tx = d.bufferedAudioTx
            val bufferedRx = d.bufferedAudioRx
            put("protocolVersion", JsonPrimitive(1))
            put("txGenerationPresent", JsonPrimitive(tx.generationId != null))
            put("txCaptureSource", JsonPrimitive(tx.captureSource))
            put("txCaptureState", JsonPrimitive(tx.captureState))
            put("txCaptureArmedAt", nullable(tx.captureArmedAtEpochMs?.let(Instant::ofEpochMilli)?.toString()))
            put("txFirstPcmAt", nullable(tx.firstPcmAtEpochMs?.let(Instant::ofEpochMilli)?.toString()))
            put("txCaptureConfirmedAt", nullable(tx.captureConfirmedAtEpochMs?.let(Instant::ofEpochMilli)?.toString()))
            put("txCaptureConfirmMs", nullable(tx.captureConfirmMs))
            put("txPreFloorNetworkEgressFrames", JsonPrimitive(tx.preFloorAudioNetworkEgressFrames))
            put("txCanonicalFramesSent", JsonPrimitive(tx.canonicalFramesSent))
            put("txCanonicalLastSequence", JsonPrimitive(tx.canonicalLastSequence))
            put("txDroppedFrames", JsonPrimitive(tx.canonicalDroppedFrames))
            put("txLastErrorCode", nullable(tx.lastErrorCode))
            put("rxGenerationPresent", JsonPrimitive(bufferedRx.generationId != null))
            put("rxPlaybackCursor", JsonPrimitive(bufferedRx.playbackCursor))
            put("rxLatestSequence", JsonPrimitive(bufferedRx.latestSequence))
            put("rxBacklogMs", JsonPrimitive(bufferedRx.backlogMs))
            put("rxPlaybackRate", JsonPrimitive(bufferedRx.playbackRate))
            put("rxTimelineLost", JsonPrimitive(bufferedRx.timelineLost))
            put("controlSenderIdentityResolution", JsonPrimitive(d.controlSenderIdentityResolution))
        })
        put("crashBreadcrumbs", buildJsonObject {
            put("previousRunTermination", JsonPrimitive(com.dennomuso.koeon.core.audio.Batv1CrashBreadcrumbs.previousRunTermination().name))
            put("events", buildJsonArray {
                com.dennomuso.koeon.core.audio.Batv1CrashBreadcrumbs.snapshot().forEach { event ->
                    add(buildJsonObject {
                        put("timestampEpochMs", JsonPrimitive(event.timestampEpochMs))
                        put("platform", JsonPrimitive(event.platform))
                        put("build", JsonPrimitive(event.build))
                        put("generation", nullable(event.generationToken))
                        put("role", JsonPrimitive(event.role))
                        put("stage", JsonPrimitive(event.stage))
                        put("threadClass", JsonPrimitive(event.threadClass))
                        put("resultClass", JsonPrimitive(event.resultClass))
                    })
                }
            })
        })
        put("platformSpecific", buildJsonObject {
            put("build", JsonPrimitive("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"))
            put("foregroundService", nullable(d.foregroundService))
            put("lastPttInput", nullable(d.lastPttInputSource?.name))
            put("appTouchDownCount", JsonPrimitive(d.appTouchDownCount))
            put("appTouchUpCount", JsonPrimitive(d.appTouchUpCount))
            put("appTouchCancelCount", JsonPrimitive(d.appTouchCancelCount))
            put("appTouchLastDownAt", nullable(d.appTouchLastDownAt))
            put("appTouchLastUpAt", nullable(d.appTouchLastUpAt))
            put("appTouchLastCancelReason", nullable(d.appTouchLastCancelReason))
            put("appTouchMoveCount", JsonPrimitive(d.appTouchMoveCount))
            put("appTouchCaptureStartedAt", nullable(d.appTouchCaptureStartedAt))
            put("appTouchCaptureEndedAt", nullable(d.appTouchCaptureEndedAt))
            put("appTouchLastTerminalReason", nullable(d.appTouchLastTerminalReason))
            put("appTouchScrollSuppressedCount", JsonPrimitive(d.appTouchScrollSuppressedCount))
            put("appTouchPointerIdPresent", JsonPrimitive(d.appTouchPointerIdPresent))
        })
    }
    return fieldDiagnosticJson.encodeToString(kotlinx.serialization.json.JsonObject.serializer(), value)
}
