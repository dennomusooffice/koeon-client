package com.dennomuso.koeon.core.ptt

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

enum class PttInputSource { APP_TOUCH, HEADSET_MEDIA_BUTTON, HARDWARE_VOLUME_BUTTON, SYSTEM_SAFETY }

sealed interface OrderedPttInputCommand {
    data class Down(val canTransmit: Boolean) : OrderedPttInputCommand
    data object Up : OrderedPttInputCommand
}

/**
 * Finishes each UP before starting a subsequent DOWN, while allowing UP to
 * cancel an in-flight DOWN immediately. This preserves short-press safety and
 * prevents release/re-arm from losing the next press.
 */
class OrderedPttInputQueue(
    scope: CoroutineScope,
    private val handle: suspend (OrderedPttInputCommand) -> Unit,
) {
    private val commands = Channel<OrderedPttInputCommand>(Channel.UNLIMITED)

    init {
        scope.launch {
            for (command in commands) {
                when (command) {
                    is OrderedPttInputCommand.Down -> launch(start = CoroutineStart.UNDISPATCHED) { handle(command) }
                    OrderedPttInputCommand.Up -> handle(command)
                }
            }
        }
    }

    fun down(canTransmit: Boolean) = commands.trySend(OrderedPttInputCommand.Down(canTransmit)).isSuccess
    fun up() = commands.trySend(OrderedPttInputCommand.Up).isSuccess
}

/** App touch is always momentary; headset mode/latch never enters this gate. */
class AppTouchPttGate {
    private var pressed = false

    fun down(): Boolean {
        if (pressed) return false
        pressed = true
        return true
    }

    fun up(): Boolean {
        if (!pressed) return false
        pressed = false
        return true
    }

    fun cancel(): Boolean = up()
    fun isPressed(): Boolean = pressed
}

fun isParentScrollEnabledWhileTouchPtt(appTouchPressed: Boolean): Boolean = !appTouchPressed

enum class HardwareVolumePttMode { OFF, TOGGLE }
enum class HardwareVolumeAction { DOWN, UP, IGNORE, PASS, VOLUME }

data class HardwareVolumePttEligibility(
    val mode: HardwareVolumePttMode,
    val joined: Boolean,
    val canPublish: Boolean,
    val audioReady: Boolean,
    val foreground: Boolean,
) {
    fun consumesVolumeKeys(): Boolean = mode == HardwareVolumePttMode.TOGGLE &&
        joined && canPublish && audioReady && foreground
}

/** Foreground latch uses the same long-press recognition as background input. */
class HardwareVolumePttGate {
    private val input = com.dennomuso.koeon.service.BackgroundVolumeKeyGate()
    private var latched = false

    fun event(key: Int, down: Boolean, repeat: Int, cancelled: Boolean,
              downAt: Long, now: Long, eligible: Boolean): HardwareVolumeAction {
        return when (input.event(key, down, repeat, cancelled, downAt, now, eligible)) {
            com.dennomuso.koeon.service.BackgroundVolumeDecision.PASS -> HardwareVolumeAction.PASS
            com.dennomuso.koeon.service.BackgroundVolumeDecision.CONSUME -> HardwareVolumeAction.IGNORE
            com.dennomuso.koeon.service.BackgroundVolumeDecision.SHORT_PRESS -> HardwareVolumeAction.VOLUME
            com.dennomuso.koeon.service.BackgroundVolumeDecision.TOGGLE -> {
                latched = !latched
                if (latched) HardwareVolumeAction.DOWN else HardwareVolumeAction.UP
            }
        }
    }
    fun clear(): Boolean {
        input.invalidate()
        val wasLatched = latched
        latched = false
        return wasLatched
    }
    fun isLatched() = latched
}
