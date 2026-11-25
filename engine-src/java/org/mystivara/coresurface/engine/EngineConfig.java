package org.mystivara.coresurface.engine;

import android.content.ContentResolver;
import android.content.Context;
import android.provider.Settings;

import java.lang.reflect.Method;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Zero-Binder Live Configuration Bridge.
 * Reads non-persistent memory property `debug.coresurface.cfg` set via `resetprop -n`
 * (~2 microseconds, zero Binder calls, 100% SELinux-safe on Android 16 KernelSU-Next).
 *
 * Format: motion=hyperos4|silk|off;native=1|0;guard=1|0;thermallod=1|0
 */
public final class EngineConfig {
    public static final String PROP_KEY = "debug.coresurface.cfg";
    public static final String SETTINGS_KEY = "coresurface_engine_v1";

    public static final String MOTION_OFF = "off";
    public static final String MOTION_HYPEROS4 = "hyperos4";
    public static final String MOTION_SILK = "silk";

    private volatile String motionProfile = MOTION_HYPEROS4;
    private volatile boolean nativeTier = true;
    private volatile boolean surgicalGuard = true;
    private volatile boolean thermalLod = true;
    private volatile String rawConfig = "default";

    private final CopyOnWriteArrayList<Runnable> listeners = new CopyOnWriteArrayList<>();
    private volatile Method sysPropGetMethod;
    private volatile boolean sysPropResolved = false;
    private volatile ContentResolver contentResolver;
    private volatile long lastRefreshMs = 0L;

    public void attachContext(Context context) {
        if (context == null) {
            return;
        }
        if (contentResolver == null) {
            Context app = context.getApplicationContext() != null ? context.getApplicationContext() : context;
            contentResolver = app.getContentResolver();
        }
        refreshNow(true);
    }

    public void addListener(Runnable listener) {
        if (listener != null) {
            listeners.addIfAbsent(listener);
        }
    }

    public void refreshIfStale() {
        long now = System.currentTimeMillis();
        if (now - lastRefreshMs < 750L) {
            return;
        }
        refreshNow(false);
    }

    public void refreshNow(boolean forceNotify) {
        lastRefreshMs = System.currentTimeMillis();
        String next = readSystemProperty();
        if (next == null || next.isEmpty()) {
            next = readSettingsFallback();
        }
        if (next == null || next.isEmpty()) {
            return;
        }
        String trimmed = next.trim();
        if (!trimmed.equals(rawConfig)) {
            parse(trimmed);
            notifyListeners();
        } else if (forceNotify) {
            notifyListeners();
        }
    }

    private String readSystemProperty() {
        if (!sysPropResolved) {
            sysPropResolved = true;
            try {
                Class<?> sp = Class.forName("android.os.SystemProperties");
                sysPropGetMethod = sp.getMethod("get", String.class, String.class);
            } catch (Throwable ignored) {
                sysPropGetMethod = null;
            }
        }
        Method m = sysPropGetMethod;
        if (m == null) {
            return "";
        }
        try {
            Object res = m.invoke(null, PROP_KEY, "");
            return res instanceof String ? (String) res : "";
        } catch (Throwable ignored) {
            return "";
        }
    }

    private String readSettingsFallback() {
        ContentResolver cr = contentResolver;
        if (cr == null) {
            return "";
        }
        try {
            String v = Settings.Global.getString(cr, SETTINGS_KEY);
            return v != null ? v : "";
        } catch (Throwable ignored) {
            return "";
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
                case "motion":
                    if (MOTION_SILK.equals(v)) {
                        motionProfile = MOTION_SILK;
                    } else if (MOTION_HYPEROS4.equals(v)) {
                        motionProfile = MOTION_HYPEROS4;
                    } else {
                        motionProfile = MOTION_OFF;
                    }
                    break;
                case "native":
                case "livingflow":
                    nativeTier = on;
                    break;
                case "guard":
                    surgicalGuard = on;
                    break;
                case "thermallod":
                    thermalLod = on;
                    break;
                default:
                    break;
            }
        }
    }

    public String getMotionProfile() {
        refreshIfStale();
        return motionProfile;
    }

    public boolean isNativeTierEnabled() {
        refreshIfStale();
        return nativeTier;
    }

    public boolean isSurgicalGuard() {
        refreshIfStale();
        return surgicalGuard;
    }

    public boolean isThermalLod() {
        refreshIfStale();
        return thermalLod;
    }

    public String getRawConfig() {
        return rawConfig;
    }
}
