package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.livekit.IntercomConnectionState
import com.dennomuso.koeon.core.livekit.AudioCaptureProfile
import com.dennomuso.koeon.core.audio.InputGainMode
import com.dennomuso.koeon.core.audio.AudioBitratePreset
import com.dennomuso.koeon.core.model.JoinResponse
import com.dennomuso.koeon.core.model.JoinChannel
import com.dennomuso.koeon.core.model.Role
import com.dennomuso.koeon.core.model.User
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class FieldDiagnosticTest {
    @Test fun subscriptionMetadataDoesNotClaimDecodedOrAudibleAudio() {
        val state = IntercomUiState(
            connectionState = IntercomConnectionState.CONNECTED,
            diagnostics = SessionDiagnostics(remoteAudioTracks = 3, remoteAudioState = "subscribed"),
        )
        val liveKit = Json.parseToJsonElement(buildAndroidFieldDiagnostic(state))
            .jsonObject.getValue("liveKit").jsonObject
        assertEquals("3", liveKit.getValue("remoteAudioTracks").jsonPrimitive.content)
        assertEquals("subscribed", liveKit.getValue("remoteAudioState").jsonPrimitive.content)
        assertEquals(kotlinx.serialization.json.JsonNull, liveKit.getValue("remoteDecodedPcmObserved"))
        assertEquals(kotlinx.serialization.json.JsonNull, liveKit.getValue("remoteAudiblePlaybackConfirmed"))
    }

    @Test fun serverVersionIsReportedSeparatelyAndUnknownRemainsNull() {
        fun value(version: String?, connection: IntercomConnectionState = IntercomConnectionState.CONNECTED) = Json.parseToJsonElement(buildAndroidFieldDiagnostic(
            IntercomUiState(connectionState = connection, diagnostics = SessionDiagnostics(liveKitServerVersion = version)),
        )).jsonObject.getValue("liveKit").jsonObject.getValue("serverVersion")
        assertEquals(kotlinx.serialization.json.JsonNull, value(null))
        assertEquals("1.13.11", value("1.13.11").jsonPrimitive.content)
        assertEquals(kotlinx.serialization.json.JsonNull, value("1.13.11", IntercomConnectionState.RECONNECTING))
        assertEquals(kotlinx.serialization.json.JsonNull, value("1.13.11", IntercomConnectionState.DISCONNECTED))
    }

    @Test fun retainedReceiveIsSeparateFromCurrentAndDoesNotInventUnmeasuredOutput() {
        val snapshot = com.dennomuso.koeon.core.audio.BufferedAudioRxSnapshot.capture(
            com.dennomuso.koeon.core.audio.BufferedAudioRxDiagnostics(
                generationId = "private-generation", playbackCursor = 42, latestSequence = 41,
                finalSequence = 41, terminalReason = "final_sequence", playerDrainCompletedAtEpochMs = 1000,
            ),
        )
        val state = IntercomUiState(diagnostics = SessionDiagnostics(lastBufferedReceive = snapshot))
        val json = buildAndroidFieldDiagnostic(state)
        val root = Json.parseToJsonElement(json).jsonObject
        val retained = root.getValue("lastBufferedReceive").jsonObject
        assertEquals(setOf("capturedAt", "build", "outcome", "terminalReason", "playbackCursor",
            "latestSequence", "finalSequence", "missingSequenceCount", "duplicateSequenceCount",
            "playerDrainCompletedAt", "endCueAt", "lastEnqueueOutput", "lastCompletionOutput",
            "engineStartFailures", "lastErrorCode", "inputRmsDbfs", "inputPeakDbfs"), retained.keys)
        assertEquals("42", retained.getValue("playbackCursor").jsonPrimitive.content)
        assertEquals("completed", retained.getValue("outcome").jsonPrimitive.content)
        assertEquals("1970-01-01T00:00:01Z", retained.getValue("playerDrainCompletedAt").jsonPrimitive.content)
        assertEquals("0", root.getValue("bufferedAudio").jsonObject.getValue("rxPlaybackCursor").jsonPrimitive.content)
        for (key in listOf("lastEnqueueOutput", "lastCompletionOutput", "engineStartFailures", "inputRmsDbfs", "inputPeakDbfs")) {
            assertEquals(kotlinx.serialization.json.JsonNull, retained.getValue(key))
        }
        assertFalse(json.contains("private-generation"))
        assertEquals(kotlinx.serialization.json.JsonNull,
            Json.parseToJsonElement(buildAndroidFieldDiagnostic(IntercomUiState())).jsonObject.getValue("lastBufferedReceive"))
    }

    @Test fun sessionMismatchDiagnosticContainsOnlyCategoryCounts() {
        val state = IntercomUiState(diagnostics = SessionDiagnostics(
            rxReadyRejectedSessionMismatch = 3,
            rxReadySessionMismatchReasons = mapOf("SDK_PARTICIPANT_MISSING" to 2, "RECEIVER_SESSION_MISMATCH" to 1),
        ))
        val rx = Json.parseToJsonElement(buildAndroidFieldDiagnostic(state)).jsonObject.getValue("rxReady").jsonObject
        val reasons = rx.getValue("rxReadySessionMismatchReasons").jsonObject
        assertEquals(setOf("SDK_PARTICIPANT_MISSING", "RECEIVER_SESSION_MISMATCH"), reasons.keys)
        assertEquals("2", reasons.getValue("SDK_PARTICIPANT_MISSING").jsonPrimitive.content)
        assertEquals("1", reasons.getValue("RECEIVER_SESSION_MISMATCH").jsonPrimitive.content)
        assertEquals("3", rx.getValue("rxReadyRejectedSessionMismatch").jsonPrimitive.content)
    }

    @Test fun commonSchemaContainsNoSecretFields() {
        val state = IntercomUiState(
            joined = true, connectionState = IntercomConnectionState.CONNECTED,
            join = JoinResponse("session", "wss://example.invalid", "redacted", "room", User("u", "w", "Staff", Role.STAFF), JoinChannel("c", "Stage"), true, 300),
        )
        val json = buildAndroidFieldDiagnostic(state, "2026-08-17T00:00:00Z")
        val root = Json.parseToJsonElement(json).jsonObject
        assertEquals(FIELD_DIAGNOSTIC_SCHEMA, root.getValue("schema").jsonPrimitive.content)
        assertEquals("READY", root.getValue("state").jsonObject.getValue("pttSemanticState").jsonPrimitive.content)
        assertFalse(Regex("token|credential|authorization|private.?key", RegexOption.IGNORE_CASE).containsMatchIn(json))
    }

    @Test fun rxReadyPublishAttemptSuccessAndFailureAreDistinguishable() {
        val attempted = "2026-08-21T00:00:00Z"
        val published = "2026-08-21T00:00:00.050Z"
        val state = IntercomUiState(
            diagnostics = SessionDiagnostics(
                rxReadyProtocolVersion = 1,
                rxReadyPublishAttemptedAt = attempted,
                rxReadyPublishedAt = published,
                rxReadyPublishResult = "SUCCESS",
                rxReadyPublishFailureClass = null,
                rxReadyStartReceivedAt = attempted,
                rxReadyStartArmedAt = published,
                rxReadySenderIdentityPresent = true,
                rxReadyReceiverDeviceIdPresent = true,
            ),
        )
        val rxReady = Json.parseToJsonElement(buildAndroidFieldDiagnostic(state)).jsonObject
            .getValue("rxReady").jsonObject
        assertEquals("1", rxReady.getValue("rxReadyProtocolVersion").jsonPrimitive.content)
        assertEquals(attempted, rxReady.getValue("rxReadyPublishAttemptedAt").jsonPrimitive.content)
        assertEquals(published, rxReady.getValue("rxReadyPublishedAt").jsonPrimitive.content)
        assertEquals("SUCCESS", rxReady.getValue("rxReadyPublishResult").jsonPrimitive.content)
        assertEquals(attempted, rxReady.getValue("rxReadyStartReceivedAt").jsonPrimitive.content)
        assertEquals(published, rxReady.getValue("rxReadyStartArmedAt").jsonPrimitive.content)
        assertEquals("true", rxReady.getValue("rxReadySenderIdentityPresent").jsonPrimitive.content)
        assertEquals("true", rxReady.getValue("rxReadyReceiverDeviceIdPresent").jsonPrimitive.content)

        val failed = Json.parseToJsonElement(buildAndroidFieldDiagnostic(
            state.copy(diagnostics = state.diagnostics.copy(
                rxReadyPublishedAt = null,
                rxReadyPublishResult = "FAILURE",
                rxReadyPublishFailureClass = "IllegalStateException",
            )),
        )).jsonObject.getValue("rxReady").jsonObject
        assertEquals("FAILURE", failed.getValue("rxReadyPublishResult").jsonPrimitive.content)
        assertEquals("IllegalStateException", failed.getValue("rxReadyPublishFailureClass").jsonPrimitive.content)
    }

    @Test fun safeProductionAudioDefaultsAreInternallyConsistent() {
        val diagnostics = SessionDiagnostics()

        assertEquals(AudioCaptureProfile.D_WEBRTC_OWNER, diagnostics.audioCaptureProfile)
        assertEquals(InputGainMode.OFF, diagnostics.inputGain.mode)
        assertEquals(0f, diagnostics.inputGain.effectiveGainDb, 0f)
        assertEquals(true, diagnostics.audioCaptureProfile.webRtcAgcEnabled)
    }

    @Test fun audioBitrateDiagnosticsSeparateSelectedRequestedAndEffectiveValues() {
        val state = IntercomUiState(diagnostics = SessionDiagnostics(
            audioBitratePreset = AudioBitratePreset.HIGH,
            requestedAudioBitrateKbps = 48,
            effectiveAudioBitrateKbps = 48,
        ))

        val audio = Json.parseToJsonElement(buildAndroidFieldDiagnostic(state)).jsonObject
            .getValue("audio").jsonObject
        assertEquals("HIGH", audio.getValue("audioBitratePreset").jsonPrimitive.content)
        assertEquals("48", audio.getValue("requestedAudioBitrateKbps").jsonPrimitive.content)
        assertEquals("48", audio.getValue("effectiveAudioBitrateKbps").jsonPrimitive.content)
    }
}
