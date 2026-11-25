package org.mystivara.coresurface.engine;

import android.content.ContentResolver;
import android.content.Context;
import android.database.ContentObserver;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;

import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Live configuration bridge over Settings.Global ("coresurface_engine_v1").
 * Readable under SELinux Enforcing by SystemUI, MiuiHome, and MiuiAod,
 * enabling instant hot-reload from the CoreSurface KernelSU WebUI without reboot.
 */
public final class EngineConfig {
    public static final String SETTINGS_KEY = "coresurface_engine_v1";

    private volatile boolean luminousGlass = true;
    private volatile boolean luminousTilt = true;
    private volatile boolean livingFlow = true;
    private volatile boolean surgicalGuard = true;
    private volatile boolean aodFlow = true;
    private volatile boolean thermalLod = true;
    private volatile String rawConfig = "default";

    private final CopyOnWriteArrayList<Runnable> listeners = new CopyOnWriteArrayList<>();
    private volatile boolean observing = false;

    public void attachContext(Context context) {
        if (context == null || observing) {
            return;
        }
        observing = true;
        final ContentResolver cr = context.getApplicationContext() != null
                ? context.getApplicationContext().getContentResolver()
                : context.getContentResolver();
        reload(cr);

        try {
            Uri uri = Settings.Global.getUriFor(SETTINGS_KEY);
            Handler mainHandler = new Handler(Looper.getMainLooper());
            cr.registerContentObserver(uri, false, new ContentObserver(mainHandler) {
                @Override
                public void onChange(boolean selfChange) {
                    reload(cr);
                    notifyListeners();
                }
            });
        } catch (Throwable ignored) {
            // Keep default or last-loaded values cleanly if observer registration fails.
        }
    }

    public void addListener(Runnable listener) {
        if (listener != null) {
            listeners.addIfAbsent(listener);
        }
    }

    private void notifyListeners() {
        for (Runnable r : listeners) {
            try {
                r.run();
            } catch (Throwable ignored) {
            }
        }
    }

    public void reload(ContentResolver cr) {
        if (cr == null) {
            return;
        }
        try {
            String value = Settings.Global.getString(cr, SETTINGS_KEY);
            if (value == null || value.trim().isEmpty()) {
                return;
            }
            parse(value);
        } catch (Throwable ignored) {
        }
    }

    public void parse(String encoded) {
        if (encoded == null || encoded.trim().isEmpty()) {
            return;
        }
        rawConfig = encoded.trim();
        String[] pairs = rawConfig.split(";");
        for (String pair : pairs) {
            int eq = pair.indexOf('=');
            if (eq <= 0 || eq >= pair.length() - 1) {
                continue;
            }
            String k = pair.substring(0, eq).trim();
            String v = pair.substring(eq + 1).trim();
            boolean on = "1".equals(v) || "true".equalsIgnoreCase(v);
            switch (k) {
                case "luminous":
                    luminousGlass = on;
                    break;
                case "tilt":
                    luminousTilt = on;
                    break;
                case "livingflow":
                    livingFlow = on;
                    break;
                case "guard":
                    surgicalGuard = on;
                    break;
                case "aodflow":
                    aodFlow = on;
                    break;
                case "thermallod":
                    thermalLod = on;
                    break;
                default:
                    break;
            }
        }
    }

    public boolean isLuminousGlass() { return luminousGlass; }
    public boolean isLuminousTilt() { return luminousTilt; }
    public boolean isLivingFlow() { return livingFlow; }
    public boolean isSurgicalGuard() { return surgicalGuard; }
    public boolean isAodFlow() { return aodFlow; }
    public boolean isThermalLod() { return thermalLod; }
    public String getRawConfig() { return rawConfig; }
}
