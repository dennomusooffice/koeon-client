package com.dennomuso.koeon.core.audio

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class AudioRoutePolicyTest {
    private val speaker = CommunicationRoute(1, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
    private val hfp = CommunicationRoute(2, AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
    private val usb = CommunicationRoute(3, AudioDeviceInfo.TYPE_USB_DEVICE)

    @Test fun selectedExternalFallbackStopsWithoutDeviceRemoval() {
        assertTrue(lostSelectedExternalRoute(hfp, speaker))
        assertTrue(lostSelectedExternalRoute(usb, speaker))
        assertTrue(lostSelectedExternalRoute(hfp, null))
    }

    @Test fun anotherExternalDeviceAlsoRequiresANewPress() {
        assertTrue(lostSelectedExternalRoute(hfp, usb))
        assertTrue(lostSelectedExternalRoute(hfp, hfp.copy(id = 4)))
    }

    @Test fun initialSelectionRepeatedCallbacksAndBuiltInSwitchesDoNotStop() {
        assertFalse(lostSelectedExternalRoute(null, hfp))
        assertFalse(lostSelectedExternalRoute(null, null))
        assertFalse(lostSelectedExternalRoute(hfp, hfp.copy()))
        assertFalse(lostSelectedExternalRoute(speaker, hfp))
        assertFalse(lostSelectedExternalRoute(speaker, CommunicationRoute(5, AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)))
    }

    @Test fun usbAndBleCommunicationRoutesAreProtectedButMediaOnlyDevicesAreNotInputs() {
        for (type in listOf(AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY,
            AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_BLE_HEADSET)) {
            assertTrue(lostSelectedExternalRoute(CommunicationRoute(8, type), null))
        }
        for (type in listOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)) {
            assertFalse(lostSelectedExternalRoute(CommunicationRoute(8, type), null))
        }
    }
}
