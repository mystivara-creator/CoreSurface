package org.mystivara.coresurface.engine;

import android.app.Activity;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
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
        String liveCfg = "";
        try {
            String raw = Settings.Global.getString(getContentResolver(), EngineConfig.SETTINGS_KEY);
            liveCfg = raw != null ? raw : "(default — open CoreSurface WebUI to customize live)";
        } catch (Throwable ignored) {
            liveCfg = "(unavailable)";
        }

        TextView title = new TextView(this);
        title.setText("CoreSurface Luminous & LivingFlow Engine v1.0.0");
        title.setTextColor(Color.parseColor("#F1F5F9"));
        title.setTextSize(19.0f);
        root.addView(title);

        TextView status = new TextView(this);
        status.setPadding(0, pad / 2, 0, pad);
        status.setTextColor(active ? Color.parseColor("#34D399") : Color.parseColor("#FBBF24"));
        status.setTextSize(15.0f);
        status.setText(active
                ? "STATUS: ACTIVE IN LSPOSED (Zero-Gimmick Runtime Ready)"
                : "STATUS: ENABLE MODULE IN LSPOSED MANAGER\nScope: System UI, System Launcher (MiuiHome), Always-on Display");
        root.addView(status);

        TextView details = new TextView(this);
        details.setTextColor(Color.parseColor("#94A3B8"));
        details.setTextSize(13.5f);
        details.setText(
                "Android SDK: " + Build.VERSION.SDK_INT + " (AGSL RuntimeShader "
                + (Build.VERSION.SDK_INT >= 33 ? "Supported" : "Requires Android 13+") + ")\n\n"
                + "Live IPC Config (Settings.Global):\n" + liveCfg + "\n\n"
                + "All toggles (Luminous Glass, Tilt Specular Light, LivingFlow Spring Physics, "
                + "Surgical Toast/Recents Guard, Thermal-Adaptive LOD) hot-reload instantly from "
                + "KernelSU-Next -> Modules -> CoreSurface -> Open WebUI (no reboot needed)."
        );
        root.addView(details);

        scroll.addView(root);
        setContentView(scroll);
    }
}
