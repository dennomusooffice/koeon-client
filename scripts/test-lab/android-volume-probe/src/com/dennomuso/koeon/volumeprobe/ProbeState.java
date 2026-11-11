package com.dennomuso.koeon.volumeprobe;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

final class ProbeState {
    static SharedPreferences prefs(Context c) { return c.getSharedPreferences("probe", Context.MODE_PRIVATE); }
    static void arm(Context c, boolean consume) {
        prefs(c).edit().clear().putBoolean("consume", consume)
            .putLong("deadline", SystemClock.elapsedRealtime() + 600000).commit();
        write(c);
    }
    static void count(SharedPreferences p, String key) {
        p.edit().putInt(key, Math.min(1000000, p.getInt(key, 0) + 1)).commit();
    }
    static void write(Context c) {
        SharedPreferences p = prefs(c);
        JSONObject j = new JSONObject();
        try {
            j.put("schema", "koeon.volume-input-probe.v1");
            j.put("consume", p.getBoolean("consume", false));
            j.put("armed", SystemClock.elapsedRealtime() < p.getLong("deadline", 0));
            for (String key : new String[]{"down", "up", "repeat", "cancelled", "interactive", "screenOff", "locked", "unlocked", "serviceConnected", "serviceInterrupted"})
                j.put(key, p.getInt(key, 0));
            j.put("lastElapsedMs", p.getLong("lastElapsedMs", 0));
            j.put("lastVolumeKey", p.getInt("lastVolumeKey", 0));
            File temp = new File(c.getFilesDir(), "state.tmp");
            try (FileOutputStream out = new FileOutputStream(temp)) { out.write(j.toString().getBytes(StandardCharsets.UTF_8)); }
            File target = new File(c.getFilesDir(), "state.json");
            if (!temp.renameTo(target)) temp.delete();
        } catch (Exception ignored) { /* No raw errors, identifiers, or event payloads in logs. */ }
    }
}
