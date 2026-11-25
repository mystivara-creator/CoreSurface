package org.mystivara.coresurface.engine;

import android.content.ContentResolver;
import android.content.Context;
import android.os.Build;
import android.os.SystemClock;
import android.provider.Settings;
import android.view.View;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Runtime Device Logic & OS Anomaly Self-Healing Guard.
 *
 * 1. Probes OS/ROM capabilities & anomalies at runtime (HyperOS blur API presence,
 *    Android SDK level, accessibility animator duration scale == 0).
 * 2. Provides per-hook fault circuit-breakers: if any OEM/HyperOS update causes a hook
 *    to throw >= MAX_HOOK_FAULTS exceptions, that hook disarms itself cleanly without
 *    ever crashing SystemUI, MiuiHome, Settings, or MiuiAod.
 */
public final class DeviceBugGuard {
    private static final int MAX_HOOK_FAULTS = 3;
    private static final long SCALE_CHECK_INTERVAL_MS = 5000L;

    private final TelemetryReporter telemetry;
    private final ConcurrentHashMap<String, AtomicInteger> faultCounts = new ConcurrentHashMap<>();

    private volatile ContentResolver contentResolver;
    private volatile boolean animationsDisabledByUser = false;
    private volatile long lastScaleCheckMs = 0L;
    private volatile boolean miBlurApiPresent = false;
    private volatile boolean probed = false;

    public DeviceBugGuard(TelemetryReporter telemetry) {
        this.telemetry = telemetry;
    }

    public void attachContext(Context context) {
        if (context == null) {
            return;
        }
        Context app = context.getApplicationContext() != null ? context.getApplicationContext() : context;
        if (contentResolver == null) {
            contentResolver = app.getContentResolver();
        }
        probeOnce();
        refreshAnimatorScaleIfStale();
    }

    private void probeOnce() {
        if (probed) {
            return;
        }
        probed = true;
        try {
            View.class.getMethod("setMiBackgroundBlurMode", int.class);
            miBlurApiPresent = true;
        } catch (Throwable ignored) {
            miBlurApiPresent = false;
        }
        // HyperOS 3+ on SDK >= 35 with MIUI blur API requires Toast/Recents blur guard
        if (Build.VERSION.SDK_INT >= 35 && miBlurApiPresent) {
            telemetry.recordOsBugMitigated("HOS3_MiBlurRuntime");
        }
    }

    public boolean isAnimationDisabledByUser() {
        refreshAnimatorScaleIfStale();
        return animationsDisabledByUser;
    }

    public boolean isHookTripped(String hookId) {
        AtomicInteger cnt = faultCounts.get(hookId);
        return cnt != null && cnt.get() >= MAX_HOOK_FAULTS;
    }

    public void recordHookFault(String hookId) {
        if (hookId == null) {
            return;
        }
        AtomicInteger cnt = faultCounts.get(hookId);
        if (cnt == null) {
            AtomicInteger created = new AtomicInteger(0);
            AtomicInteger prev = faultCounts.putIfAbsent(hookId, created);
            cnt = prev != null ? prev : created;
        }
        int total = cnt.incrementAndGet();
        if (total == MAX_HOOK_FAULTS) {
            telemetry.incCircuitTrips();
        }
    }

    public boolean hasMiBlurApi() {
        probeOnce();
        return miBlurApiPresent;
    }

    private void refreshAnimatorScaleIfStale() {
        long now = SystemClock.uptimeMillis();
        if (now - lastScaleCheckMs < SCALE_CHECK_INTERVAL_MS) {
            return;
        }
        lastScaleCheckMs = now;
        ContentResolver cr = contentResolver;
        if (cr == null) {
            return;
        }
        try {
            float scale = Settings.Global.getFloat(cr, Settings.Global.ANIMATOR_DURATION_SCALE, 1.0f);
            animationsDisabledByUser = (scale <= 0.01f);
        } catch (Throwable ignored) {
            animationsDisabledByUser = false;
        }
    }
}
