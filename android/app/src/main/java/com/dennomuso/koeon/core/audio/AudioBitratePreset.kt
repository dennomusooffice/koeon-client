package com.dennomuso.koeon.core.audio

enum class AudioBitratePreset(val kilobitsPerSecond: Int) {
    LOW(12),
    STANDARD(24),
    HIGH(48),
    ;

    val bitsPerSecond: Int get() = kilobitsPerSecond * 1_000

    companion object {
        val DEFAULT = STANDARD

        fun fromPersisted(value: String?): AudioBitratePreset =
            entries.firstOrNull { it.name == value } ?: DEFAULT
    }
}

internal const val AUDIO_BITRATE_PREFERENCE_KEY = "audio_bitrate_preset"

/** Keeps persistence testable without exposing Android storage to the domain contract. */
internal class AudioBitratePreferenceStore(
    private val read: () -> String?,
    private val write: (String) -> Unit,
) {
    fun load(): AudioBitratePreset = AudioBitratePreset.fromPersisted(read())

    fun save(preset: AudioBitratePreset) = write(preset.name)
}
