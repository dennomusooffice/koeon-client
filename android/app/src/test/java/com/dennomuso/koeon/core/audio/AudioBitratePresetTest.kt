package com.dennomuso.koeon.core.audio

import com.dennomuso.koeon.core.livekit.AudioCaptureProfile
import com.dennomuso.koeon.core.livekit.audioTrackPublishDefaults
import org.junit.Assert.assertEquals
import org.junit.Test

class AudioBitratePresetTest {
    @Test fun approvedValuesAndDefaultAreStable() {
        assertEquals(12, AudioBitratePreset.LOW.kilobitsPerSecond)
        assertEquals(24, AudioBitratePreset.STANDARD.kilobitsPerSecond)
        assertEquals(48, AudioBitratePreset.HIGH.kilobitsPerSecond)
        assertEquals(AudioBitratePreset.STANDARD, AudioBitratePreset.DEFAULT)
    }

    @Test fun missingOrInvalidPersistedValueFailsClosedTo24Kbps() {
        assertEquals(AudioBitratePreset.STANDARD, AudioBitratePreset.fromPersisted(null))
        assertEquals(AudioBitratePreset.STANDARD, AudioBitratePreset.fromPersisted("INVALID"))
    }

    @Test fun selectionSurvivesStoreRecreation() {
        var persisted: String? = null
        AudioBitratePreferenceStore({ persisted }, { persisted = it }).save(AudioBitratePreset.HIGH)

        val restartedStore = AudioBitratePreferenceStore({ persisted }, { persisted = it })
        assertEquals(AudioBitratePreset.HIGH, restartedStore.load())
    }

    @Test fun everyPresetMapsToTheLiveKitPublishBitrate() {
        assertEquals(12_000, audioTrackPublishDefaults(AudioBitratePreset.LOW).audioBitrate)
        assertEquals(24_000, audioTrackPublishDefaults(AudioBitratePreset.STANDARD).audioBitrate)
        assertEquals(48_000, audioTrackPublishDefaults(AudioBitratePreset.HIGH).audioBitrate)
    }

    @Test fun bitrateMappingIsIndependentFromCaptureProcessingProfiles() {
        AudioCaptureProfile.entries.forEach { _ ->
            assertEquals(24_000, audioTrackPublishDefaults(AudioBitratePreset.STANDARD).audioBitrate)
        }
    }
}
