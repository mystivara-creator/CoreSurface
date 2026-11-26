package org.mystivara.coresurface.engine;

import android.content.ContentResolver;
import android.content.Context;
import android.os.SystemClock;
import android.provider.Settings;

import java.lang.reflect.Method;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Zero-Binder Live Configuration Bridge (ultra-lightweight hot-path).
 * Reads non-persistent memory property `debug.coresurface.cfg` set via `resetprop -n`
 * (~2 microseconds, zero Binder calls on UI frames, 100% SELinux-safe on Android 16 KernelSU-Next).
 *
 * Format: motion=snappy|fluid|bouncy|off;native=1|0;guard=1|0;thermallod=1|0;aod=1|0
 */
public final class EngineConfig {
    public static final String PROP_KEY = "debug.coresurface.cfg";
    public static final String SETTINGS_KEY = "coresurface_engine_v1";

    public static final String MOTION_OFF = "off";
    public static final String MOTION_SNAPPY = "snappy";
    public static final String MOTION_FLUID = "fluid";
    public static final String MOTION_BOUNCY = "bouncy";

    private static final long REFRESH_INTERVAL_MS = 1500L;
    private static final Object[] PROP_ARGS = new Object[] { PROP_KEY, "" };

    private volatile String motionProfile = MOTION_OFF;
    private volatile boolean nativeTier = true;
    private volatile boolean surgicalGuard = true;
    private volatile boolean thermalLod = true;
    private volatile boolean aodUnlock = true;
    private volatile String rawConfig = "default";

    private final CopyOnWriteArrayList<Runnable> listeners = new CopyOnWriteArrayList<>();
    private final AtomicBoolean refreshing = new AtomicBoolean(false);
    private volatile Method sysPropGetMethod;
    private volatile boolean sysPropResolved = false;
    private volatile boolean settingsFallbackTried = false;
    private volatile ContentResolver contentResolver;
    private volatile long lastRefreshMs = -REFRESH_INTERVAL_MS;

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
        long now = SystemClock.uptimeMillis();
        if (now - lastRefreshMs < REFRESH_INTERVAL_MS) {
            return;
        }
        if (!refreshing.compareAndSet(false, true)) {
            return;
        }
        try {
            refreshNowInternal(false, now, false);
        } finally {
            refreshing.set(false);
        }
    }

    public void refreshNow(boolean forceNotify) {
        refreshNowInternal(forceNotify, SystemClock.uptimeMillis(), true);
    }

    private void refreshNowInternal(boolean forceNotify, long now, boolean allowSettingsFallback) {
        lastRefreshMs = now;
        String next = readSystemProperty();
        if ((next == null || next.isEmpty()) && allowSettingsFallback && !settingsFallbackTried) {
            // Query Settings.Global at most once during startup bootstrap — NEVER on UI animation frames
            settingsFallbackTried = true;
            next = readSettingsFallback();
        }
        if (next == null || next.isEmpty()) {
            if (forceNotify) {
                notifyListeners();
            }
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
            Object res = m.invoke(null, PROP_ARGS);
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
        if (encoded == null) {
            return;
        }
        String trimmed = encoded.trim();
        if (trimmed.isEmpty()) {
            return;
        }
        rawConfig = trimmed;
        int len = trimmed.length();
        int start = 0;
        while (start < len) {
            int semi = trimmed.indexOf(';', start);
            int end = semi < 0 ? len : semi;
            int eq = trimmed.indexOf('=', start);
            if (eq > start && eq < end - 1) {
                String k = trimmed.substring(start, eq).trim();
                String v = trimmed.substring(eq + 1, end).trim();
                boolean on = "1".equals(v) || "true".equalsIgnoreCase(v);
                switch (k) {
                    case "motion":
                        motionProfile = MotionProfileSpec.normalizeProfile(v);
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
                    case "aod":
                        aodUnlock = on;
                        break;
                    default:
                        break;
                }
            }
            if (semi < 0) {
                break;
            }
            start = semi + 1;
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

    /** Zero-syscall single volatile read for ultra-hot device-level getters (thousands/sec). */
    public boolean isNativeTierEnabledFast() {
        return nativeTier;
    }

    public boolean isSurgicalGuard() {
        refreshIfStale();
        return surgicalGuard;
    }

    /** Zero-syscall single volatile read for hot View blur setters. */
    public boolean isSurgicalGuardFast() {
        return surgicalGuard;
    }

    public boolean isThermalLod() {
        return thermalLod;
    }

    public boolean isAodUnlockEnabled() {
        refreshIfStale();
        return aodUnlock;
    }

    /** Zero-syscall single volatile read for AOD FeatureParser / capability gates. */
    public boolean isAodUnlockEnabledFast() {
        return aodUnlock;
    }

    public String getRawConfig() {
        return rawConfig;
    }
}
