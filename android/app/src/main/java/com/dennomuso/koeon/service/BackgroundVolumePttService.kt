package com.dennomuso.koeon.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Intent
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import com.dennomuso.koeon.KoeonApplication
import java.lang.ref.WeakReference

/** Only volume key edges; no accessibility content, gestures, or application launch. */
class BackgroundVolumePttService : AccessibilityService() {
    private val gate = BackgroundVolumeKeyGate()
    private val manager get() = (application as KoeonApplication).intercomSession

    override fun onServiceConnected() {
        active = WeakReference(this)
        serviceInfo = serviceInfo.apply {
            eventTypes = 0
            flags = AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS
        }
        manager.onBackgroundVolumeServiceChanged(true, "CONNECTED")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() { gate.invalidate(); manager.cancelBackgroundVolumePtt() }
    override fun onUnbind(intent: Intent?): Boolean {
        gate.invalidate()
        if (active?.get() === this) active = null
        manager.onBackgroundVolumeServiceChanged(false, "UNBOUND")
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        gate.invalidate()
        if (active?.get() === this) active = null
        manager.onBackgroundVolumeServiceChanged(false, "DESTROYED")
        super.onDestroy()
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode != KeyEvent.KEYCODE_VOLUME_UP && event.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) return false
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return false
        val result = gate.event(event.keyCode, event.action == KeyEvent.ACTION_DOWN, event.repeatCount,
            event.isCanceled || event.isLongPress, event.downTime, event.eventTime,
            manager.backgroundVolumePttEligible())
        if (result == BackgroundVolumeDecision.TOGGLE) manager.toggleBackgroundVolumePtt()
        return result != BackgroundVolumeDecision.PASS
    }

    companion object {
        private var active: WeakReference<BackgroundVolumePttService>? = null
        fun invalidatePendingInput() { active?.get()?.gate?.invalidate() }
    }
}
