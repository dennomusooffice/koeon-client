package com.dennomuso.koeon.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Intent
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import com.dennomuso.koeon.KoeonApplication
import java.lang.ref.WeakReference
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/** Only volume key edges; no accessibility content, gestures, or application launch. */
class BackgroundVolumePttService : AccessibilityService() {
    private val gate = BackgroundVolumeKeyGate()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val hold = VolumeHoldTimer(scope, SystemClock::uptimeMillis)
    private fun invalidate() { hold.clear(); gate.invalidate() }
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
    override fun onInterrupt() { invalidate(); manager.cancelBackgroundVolumePtt() }
    override fun onUnbind(intent: Intent?): Boolean {
        invalidate()
        if (active?.get() === this) active = null
        manager.onBackgroundVolumeServiceChanged(false, "UNBOUND")
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        invalidate()
        if (active?.get() === this) active = null
        manager.onBackgroundVolumeServiceChanged(false, "DESTROYED")
        scope.cancel()
        super.onDestroy()
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode != KeyEvent.KEYCODE_VOLUME_UP && event.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) return false
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return false
        val result = gate.event(event.keyCode, event.action == KeyEvent.ACTION_DOWN, event.repeatCount,
            event.isCanceled, event.downTime, event.eventTime,
            manager.backgroundVolumePttEligible())
        if (event.action == KeyEvent.ACTION_UP) hold.release(event.keyCode)
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 && result == BackgroundVolumeDecision.CONSUME) {
            val key = event.keyCode
            val downAt = event.downTime
            hold.start(key, downAt) {
                val held = gate.event(key, true, 1, false, downAt, SystemClock.uptimeMillis(),
                    manager.backgroundVolumePttEligible())
                if (held == BackgroundVolumeDecision.TOGGLE) manager.toggleBackgroundVolumePtt()
            }
        }
        if (result == BackgroundVolumeDecision.TOGGLE) manager.toggleBackgroundVolumePtt()
        if (result == BackgroundVolumeDecision.SHORT_PRESS) manager.adjustShortHardwareVolume(event.keyCode)
        return result != BackgroundVolumeDecision.PASS
    }

    companion object {
        private var active: WeakReference<BackgroundVolumePttService>? = null
        fun invalidatePendingInput() { active?.get()?.invalidate() }
    }
}
