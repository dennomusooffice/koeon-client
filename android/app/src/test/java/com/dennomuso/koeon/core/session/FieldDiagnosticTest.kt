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
