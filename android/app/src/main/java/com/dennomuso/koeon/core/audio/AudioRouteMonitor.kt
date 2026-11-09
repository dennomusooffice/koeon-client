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

/** IDs are ephemeral comparison keys only; never include them in diagnostics. */
internal data class CommunicationRoute(val id: Int, val type: Int)

internal fun isExternalCommunicationType(type: Int): Boolean = type in setOf(
    AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET,
    AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_USB_HEADSET,
    AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY,
)

internal fun lostSelectedExternalRoute(previous: CommunicationRoute?, current: CommunicationRoute?): Boolean =
    previous != null && isExternalCommunicationType(previous.type) && previous != current

/** Observes routing; the SDK owns routing and AudioFocusOwner owns focus. */
class AudioRouteMonitor(private val context: Context) {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val _route = MutableStateFlow("Unavailable")
    val route: StateFlow<String> = _route.asStateFlow()
    private val _events = MutableSharedFlow<AudioRouteEvent>(extraBufferCapacity = 8)
    val events: SharedFlow<AudioRouteEvent> = _events.asSharedFlow()
    private var deviceCallback: AudioDeviceCallback? = null
    private var communicationListener: AudioManager.OnCommunicationDeviceChangedListener? = null
    private var generation = 0L
    private var selectedRoute: CommunicationRoute? = null

    // Safety delivery is independent of the bounded diagnostic event stream.
    var onExternalRouteLost: (() -> Unit)? = null

    fun start() {
        if (deviceCallback != null) { refresh(); return }
        val currentGeneration = ++generation
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                if (currentGeneration == generation) refreshWithEvent("device_added", false)
            }
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                if (currentGeneration == generation) refreshWithEvent(
                    "device_removed", removedDevices.any { isExternalCommunicationType(it.type) },
                )
            }
        }
        deviceCallback = callback
        audioManager.registerAudioDeviceCallback(callback, null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val listener = AudioManager.OnCommunicationDeviceChangedListener { selected ->
                // Preserve intermediate route loss even if the OS has already switched back.
                if (currentGeneration == generation) observeSelection("communication_device_changed", false, selected)
            }
            communicationListener = listener
            audioManager.addOnCommunicationDeviceChangedListener(context.mainExecutor, listener)
        }
        refresh()
    }

    fun stop() {
        generation++
        deviceCallback?.let(audioManager::unregisterAudioDeviceCallback)
        deviceCallback = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            communicationListener?.let(audioManager::removeOnCommunicationDeviceChangedListener)
        }
        communicationListener = null
        selectedRoute = null
        _route.value = "Unavailable"
    }

    fun refresh() { refreshWithEvent("route_refresh", false) }

    private fun refreshWithEvent(reason: String, removedExternal: Boolean) {
        if (deviceCallback == null) return
        val selected = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.communicationDevice
        } else {
            // API 29/30 exposes available devices, not the selected communication device.
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull(::isCommunicationRoute)
        }
        observeSelection(reason, removedExternal, selected)
    }

    private fun observeSelection(reason: String, removedExternal: Boolean, selected: AudioDeviceInfo?) {
        val previous = _route.value
        val next = selected?.let { CommunicationRoute(it.id, it.type) }
        val lost = removedExternal || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            lostSelectedExternalRoute(selectedRoute, next))
        selectedRoute = next
        _route.value = selected?.let(::routeLabel) ?: "Built-in speaker / earpiece"
        if (lost) onExternalRouteLost?.invoke()
        if (lost || previous != _route.value || reason != "route_refresh") {
            _events.tryEmit(AudioRouteEvent(reason, previous, _route.value, lost))
        }
    }

    private fun isCommunicationRoute(device: AudioDeviceInfo): Boolean =
        isExternalCommunicationType(device.type) || device.type in setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        )

    private fun routeLabel(device: AudioDeviceInfo): String = when (device.type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "Bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET -> "Wired headset"
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB audio"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Speaker"
        else -> "Communication device"
    }
}
