package com.dennomuso.koeon.volumeprobe;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.provider.Settings;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private TextView status;
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL); layout.setPadding(32, 48, 32, 32);
        TextView description = new TextView(this);
        description.setText("Temporary volume-key delivery test. No screen content, microphone, network, or other keys. Each arm lasts 10 minutes. Consume prevents normal volume adjustment. Disable and uninstall after the test.");
        layout.addView(description);
        button(layout, "Accessibility settings", () -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        button(layout, "Observe for 10 minutes", () -> { ProbeState.arm(this, false); refresh(); });
        button(layout, "Consume for 10 minutes", () -> { ProbeState.arm(this, true); refresh(); });
        button(layout, "Disarm", () -> { ProbeState.prefs(this).edit().putLong("deadline", 0).commit(); ProbeState.write(this); refresh(); });
        status = new TextView(this); layout.addView(status); setContentView(layout); refresh();
    }
    private void button(LinearLayout layout, String title, Runnable action) {
        Button b = new Button(this); b.setText(title); b.setOnClickListener(v -> action.run()); layout.addView(b);
    }
    private void refresh() {
        if (status != null) status.setText("DOWN=" + ProbeState.prefs(this).getInt("down", 0) + " UP=" + ProbeState.prefs(this).getInt("up", 0));
    }
    @Override protected void onResume() { super.onResume(); refresh(); }
}
