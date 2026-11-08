package com.dennomuso.koeon.core.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import io.livekit.android.audio.AudioHandler
import io.livekit.android.audio.AudioSwitchHandler

/** Keep SDK routing, but own focus requests so recovery can verify the OS result. */
class RecoverableAudioHandler(
    context: Context,
    private val routing: AudioSwitchHandler,
    onGranted: () -> Unit,
    onLost: (String) -> Unit,
) : AudioHandler {
    private val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var request: AudioFocusRequest? = null
    private val owner = AudioFocusOwner(object : FocusRequester {
        override fun request(onChange: (FocusSignal) -> Unit): Boolean {
            val next = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAcceptsDelayedFocusGain(false)
                .setOnAudioFocusChangeListener({ change ->
                    when (change) {
                        AudioManager.AUDIOFOCUS_GAIN -> onChange(FocusSignal.GAIN)
                        AudioManager.AUDIOFOCUS_LOSS -> onChange(FocusSignal.LOSS)
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> onChange(FocusSignal.TRANSIENT_LOSS)
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> onChange(FocusSignal.DUCK)
                    }
                }, Handler(Looper.getMainLooper())).build()
            request = next
            return runCatching { manager.requestAudioFocus(next) }
                .getOrDefault(AudioManager.AUDIOFOCUS_REQUEST_FAILED) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
        override fun abandon() {
            request?.let(manager::abandonAudioFocusRequest)
            request = null
        }
    }, onGranted = {
        routing.start()
        onGranted()
    }, onLost = { reason ->
        routing.stop()
        onLost(reason)
    })

    init { routing.manageAudioFocus = false }
    val hasFocus: Boolean get() = owner.hasFocus
    override fun start() = owner.start()
    override fun stop() { owner.stop(); routing.stop() }
    fun resumeFocus(): Boolean = owner.resume()
}
