package org.mystivara.coresurface.engine;

import android.app.Activity;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * Lightweight zero-bloat status screen opened from LSPosed Manager.
 * All live controls live in the unified CoreSurface KernelSU-Next WebUI.
 */
public final class EngineStatusActivity extends Activity {

    public static boolean isModuleActive() {
        return false;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Color.parseColor("#0B0F17"));

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (20 * getResources().getDisplayMetrics().density);
        root.setPadding(pad, pad * 2, pad, pad);

        boolean active = isModuleActive();
        EngineConfig cfg = new EngineConfig();
        cfg.attachContext(this);
        String liveCfg = cfg.getRawConfig();

        TextView title = new TextView(this);
        title.setText("CoreSurface Flagship Motion Engine v1.0.0");
        title.setTextColor(Color.parseColor("#F1F5F9"));
        title.setTextSize(19.0f);
        root.addView(title);

        TextView status = new TextView(this);
        status.setPadding(0, pad / 2, 0, pad);
        status.setTextColor(active ? Color.parseColor("#34D399") : Color.parseColor("#FBBF24"));
        status.setTextSize(15.0f);
        status.setText(active
                ? "STATUS: ACTIVE IN LSPOSED (60/90/120 Hz Folme + Universal UI Curves)"
                : "STATUS: ENABLE MODULE IN LSPOSED MANAGER\nScope: System UI, System Launcher (MiuiHome), Always-on Display, Settings");
        root.addView(status);

        TextView details = new TextView(this);
        details.setTextColor(Color.parseColor("#94A3B8"));
        details.setTextSize(13.5f);
        details.setText(
                "Android SDK: " + Build.VERSION.SDK_INT + " · Mode: Pure Flagship Motion (100% Original UI)\n"
                + "Motion Profile: " + cfg.getMotionProfile() + "\n"
                + "Native Tier: " + (cfg.isNativeTierEnabled() ? "ON" : "OFF")
                + " · Surgical Guard: " + (cfg.isSurgicalGuard() ? "ON" : "OFF") + "\n"
                + "Thermal Safety: " + (cfg.isThermalLod() ? "ON" : "OFF")
                + " · Non-LTPO AOD: " + (cfg.isAodUnlockEnabled() ? "ON" : "OFF") + "\n\n"
                + "Live IPC Config (debug.coresurface.cfg):\n" + liveCfg + "\n\n"
                + "All controls hot-reload without Binder errors and without reboot from "
                + "KernelSU-Next -> Modules -> CoreSurface -> Open WebUI."
        );
        root.addView(details);

        scroll.addView(root);
        setContentView(scroll);
    }
}
