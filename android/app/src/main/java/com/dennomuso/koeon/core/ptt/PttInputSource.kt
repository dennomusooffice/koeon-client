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
enum class HardwareVolumeAction { DOWN, UP, IGNORE }

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

/** Completed short presses toggle a latch; repeat/long sequences never toggle. */
class HardwareVolumePttGate {
    private var keyDown = false
    private var repeated = false
    private var latched = false

    fun keyDown(repeatCount: Int): HardwareVolumeAction {
        if (repeatCount > 0) repeated = true
        else if (!keyDown) { keyDown = true; repeated = false }
        return HardwareVolumeAction.IGNORE
    }

    fun keyUp(longPress: Boolean): HardwareVolumeAction {
        if (!keyDown) return HardwareVolumeAction.IGNORE
        keyDown = false
        if (repeated || longPress) { repeated = false; return HardwareVolumeAction.IGNORE }
        latched = !latched
        return if (latched) HardwareVolumeAction.DOWN else HardwareVolumeAction.UP
    }

    fun clear(): Boolean {
        keyDown = false
        repeated = false
        val wasLatched = latched
        latched = false
        return wasLatched
    }

    fun isLatched() = latched
}
