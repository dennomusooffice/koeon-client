package com.dennomuso.koeon.core.livekit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioCapturePolicyTest {
    @Test
    fun `production capture policy explicitly enables standard processing`() {
        assertEquals(AudioCaptureProfile.D_WEBRTC_OWNER, productionAudioCaptureProfile)
        assertEquals(com.dennomuso.koeon.core.audio.InputGainMode.OFF, productionAudioCaptureProfile.koeonGainMode)
        val policy = productionAudioCaptureProfile.capturePolicy
        assertTrue(policy.echoCancellation)
        assertTrue(policy.noiseSuppression)
        assertTrue(policy.autoGainControl)
        assertTrue(policy.highPassFilter)
        assertTrue(policy.typingNoiseDetection)
    }

    @Test
    fun `profiles isolate gain owners while preserving AEC and NS`() {
        AudioCaptureProfile.entries.forEach { profile ->
            assertTrue(profile.capturePolicy.echoCancellation)
            assertTrue(profile.capturePolicy.noiseSuppression)
            assertTrue(profile.capturePolicy.highPassFilter)
        }
        assertEquals(true, AudioCaptureProfile.A_CURRENT.capturePolicy.autoGainControl)
        assertEquals(com.dennomuso.koeon.core.audio.InputGainMode.AUTO, AudioCaptureProfile.A_CURRENT.koeonGainMode)
        assertEquals(false, AudioCaptureProfile.B_GAIN_OFF.capturePolicy.autoGainControl)
        assertEquals(com.dennomuso.koeon.core.audio.InputGainMode.OFF, AudioCaptureProfile.B_GAIN_OFF.koeonGainMode)
        assertEquals(false, AudioCaptureProfile.C_KOEON_OWNER.capturePolicy.autoGainControl)
        assertEquals(com.dennomuso.koeon.core.audio.InputGainMode.AUTO, AudioCaptureProfile.C_KOEON_OWNER.koeonGainMode)
        assertEquals(true, AudioCaptureProfile.D_WEBRTC_OWNER.capturePolicy.autoGainControl)
        assertEquals(com.dennomuso.koeon.core.audio.InputGainMode.OFF, AudioCaptureProfile.D_WEBRTC_OWNER.koeonGainMode)
    }

    @Test
    fun `endpoint diagnostic exposes host only`() {
        assertEquals(
            LiveKitEndpointDiagnostic("SELF_HOST", "livekit.example.invalid"),
            liveKitEndpointDiagnostic("wss://livekit.example.invalid"),
        )
        assertEquals(
            LiveKitEndpointDiagnostic("CLOUD", "example.livekit.cloud"),
            liveKitEndpointDiagnostic("wss://example.livekit.cloud"),
        )
        assertNull(liveKitEndpointDiagnostic("not a URL").host)
    }
}
