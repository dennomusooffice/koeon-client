package com.dennomuso.koeon.core.audio

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.asSharedFlow

data class AudioRouteEvent(
    val reason: String,
    val previousRoute: String,
    val currentRoute: String,
    val lostExternalInputRoute: Boolean,
)

/** LiveKit's AudioSwitch handler owns audio focus/routing; this class exposes its result. */
class AudioRouteMonitor(context: Context) {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val _route = MutableStateFlow("Unavailable")
    val route: StateFlow<String> = _route.asStateFlow()
    private val _events = MutableSharedFlow<AudioRouteEvent>(extraBufferCapacity = 8)
    val events: SharedFlow<AudioRouteEvent> = _events.asSharedFlow()
    private var registered = false

    private val callback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = refreshWithEvent("device_added", false)
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = refreshWithEvent(
            reason = "device_removed",
            lostExternalInputRoute = removedDevices.any(::isExternalCommunicationRoute),
        )
    }

    fun start() {
        if (!registered) {
            audioManager.registerAudioDeviceCallback(callback, null)
            registered = true
        }
        refresh()
    }

    fun stop() {
        if (registered) {
            audioManager.unregisterAudioDeviceCallback(callback)
            registered = false
        }
        _route.value = "Unavailable"
    }

    fun refresh() {
        val selected = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.communicationDevice
        } else {
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull(::isCommunicationRoute)
        }
        _route.value = selected?.let(::routeLabel) ?: "Built-in speaker / earpiece"
    }

    private fun refreshWithEvent(reason: String, lostExternalInputRoute: Boolean) {
        val previous = _route.value
        refresh()
        _events.tryEmit(AudioRouteEvent(reason, previous, _route.value, lostExternalInputRoute))
    }

    private fun isExternalCommunicationRoute(device: AudioDeviceInfo): Boolean = when (device.type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        -> true
        else -> false
    }

    private fun isCommunicationRoute(device: AudioDeviceInfo): Boolean = when (device.type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        -> true
        else -> false
    }

    private fun routeLabel(device: AudioDeviceInfo): String = when (device.type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        -> "Bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        -> "Wired headset"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Speaker"
        else -> "Communication device"
    }
}
