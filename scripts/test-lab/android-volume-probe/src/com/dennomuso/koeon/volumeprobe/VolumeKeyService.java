package com.dennomuso.koeon.volumeprobe;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.KeyguardManager;
import android.content.SharedPreferences;
import android.os.PowerManager;
import android.os.SystemClock;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;

public final class VolumeKeyService extends AccessibilityService {
    @Override protected void onServiceConnected() {
        AccessibilityServiceInfo info = getServiceInfo();
        info.eventTypes = 0; // No application/window accessibility events.
        info.flags = AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS;
        setServiceInfo(info);
        ProbeState.count(ProbeState.prefs(this), "serviceConnected");
        ProbeState.write(this);
    }
    @Override public void onAccessibilityEvent(AccessibilityEvent event) { }
    @Override public void onInterrupt() {
        ProbeState.count(ProbeState.prefs(this), "serviceInterrupted");
        ProbeState.write(this);
    }
    @Override protected boolean onKeyEvent(KeyEvent event) {
        int key = event.getKeyCode();
        if (key != KeyEvent.KEYCODE_VOLUME_UP && key != KeyEvent.KEYCODE_VOLUME_DOWN) return false;
        SharedPreferences p = ProbeState.prefs(this);
        long now = SystemClock.elapsedRealtime();
        if (now >= p.getLong("deadline", 0)) return false;
        if (event.getAction() == KeyEvent.ACTION_DOWN) ProbeState.count(p, "down");
        if (event.getAction() == KeyEvent.ACTION_UP) ProbeState.count(p, "up");
        if (event.getRepeatCount() > 0) ProbeState.count(p, "repeat");
        if (event.isCanceled()) ProbeState.count(p, "cancelled");
        ProbeState.count(p, getSystemService(PowerManager.class).isInteractive() ? "interactive" : "screenOff");
        ProbeState.count(p, getSystemService(KeyguardManager.class).isKeyguardLocked() ? "locked" : "unlocked");
        p.edit().putLong("lastElapsedMs", now).putInt("lastVolumeKey", key).commit();
        ProbeState.write(this);
        return p.getBoolean("consume", false);
    }
}
