package com.dennomuso.koeon.service

import android.view.KeyEvent

enum class HeadsetPttAction { DOWN, UP, IGNORE }
enum class HeadsetPttMode { MOMENTARY, TOGGLE }

data class HeadsetPttEligibility(
    val settingEnabled: Boolean,
    val joined: Boolean,
    val canPublish: Boolean,
    val audioReady: Boolean,
    val mode: HeadsetPttMode = HeadsetPttMode.TOGGLE,
)

/** Pure safety gate used before media keys can reach the normal Floor/PTT pipeline. */
class HeadsetPttPolicy {
    private var pressed = false
    private var latched = false

    fun evaluate(event: KeyEvent, eligibility: HeadsetPttEligibility): HeadsetPttAction =
        evaluate(event.keyCode, event.action, event.repeatCount, eligibility)

    fun evaluate(
        keyCode: Int,
        action: Int,
        repeatCount: Int,
        eligibility: HeadsetPttEligibility,
    ): HeadsetPttAction {
        if (!eligibility.settingEnabled || !eligibility.joined || !eligibility.canPublish || !eligibility.audioReady) {
            pressed = false
            latched = false
            return HeadsetPttAction.IGNORE
        }
        if (keyCode !in SUPPORTED_KEYS) return HeadsetPttAction.IGNORE
        if (eligibility.mode == HeadsetPttMode.TOGGLE) {
            return when (action) {
                KeyEvent.ACTION_DOWN -> {
                    if (repeatCount != 0 || pressed) HeadsetPttAction.IGNORE
                    else {
                        pressed = true
                        latched = !latched
                        if (latched) HeadsetPttAction.DOWN else HeadsetPttAction.UP
                    }
                }
                KeyEvent.ACTION_UP -> {
                    pressed = false
                    HeadsetPttAction.IGNORE
                }
                else -> HeadsetPttAction.IGNORE
            }
        }
        return when (action) {
            KeyEvent.ACTION_DOWN -> {
                if (repeatCount != 0 || pressed) HeadsetPttAction.IGNORE
                else {
                    pressed = true
                    HeadsetPttAction.DOWN
                }
            }
            KeyEvent.ACTION_UP -> {
                if (!pressed) HeadsetPttAction.IGNORE
                else {
                    pressed = false
                    HeadsetPttAction.UP
                }
            }
            else -> HeadsetPttAction.IGNORE
        }
    }

    fun forceRelease(): Boolean = (pressed || latched).also {
        pressed = false
        latched = false
    }

    companion object {
        val SUPPORTED_KEYS = setOf(
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_STOP,
        )
    }
}

internal enum class RouteLossPttAction { STOP_TX, KEEP_RX }

internal fun routeLossPttAction(lostExternalInputRoute: Boolean, pttActive: Boolean): RouteLossPttAction =
    if (lostExternalInputRoute && pttActive) RouteLossPttAction.STOP_TX else RouteLossPttAction.KEEP_RX
