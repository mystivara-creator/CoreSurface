package org.mystivara.coresurface.engine;

import android.content.ContentResolver;
import android.content.Context;
import android.database.ContentObserver;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.View;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Runtime Device Logic & OS Anomaly Self-Healing Guard (Zero-Overhead Hot Path).
 *
 * 1. Probes OS/ROM capabilities once at startup and observes Settings.Global.ANIMATOR_DURATION_SCALE
 *    via an event-driven ContentObserver (ZERO Binder IPC & ZERO syscalls on UI animation frames).
 * 2. Provides per-hook fault circuit-breakers with a single volatile boolean fast-path
 *    (0 ConcurrentHashMap lookups while healthy; auto-disarms any hook after >= MAX_HOOK_FAULTS).
 */
public final class DeviceBugGuard {
    private static final int MAX_HOOK_FAULTS = 3;

    private final TelemetryReporter telemetry;
    private final ConcurrentHashMap<String, AtomicInteger> faultCounts = new ConcurrentHashMap<>();

    private volatile ContentResolver contentResolver;
    private volatile boolean animationsDisabledByUser = false;
    private volatile boolean anyFaultRecorded = false;
    private volatile boolean miBlurApiPresent = false;
    private volatile boolean probed = false;
    private volatile boolean observerRegistered = false;

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
        readAnimatorScaleNow();
        registerScaleObserverOnce();
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

    private void registerScaleObserverOnce() {
        if (observerRegistered) {
            return;
        }
        ContentResolver cr = contentResolver;
        if (cr == null) {
            return;
        }
        observerRegistered = true;
        try {
            cr.registerContentObserver(
                    Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE),
                    false,
                    new ContentObserver(new Handler(Looper.getMainLooper())) {
                        @Override
                        public void onChange(boolean selfChange) {
                            readAnimatorScaleNow();
                        }
                    });
        } catch (Throwable ignored) {
        }
    }

    public boolean isAnimationDisabledByUser() {
        return animationsDisabledByUser;
    }

    public boolean isHookTripped(String hookId) {
        if (!anyFaultRecorded) {
            return false;
        }
        AtomicInteger cnt = faultCounts.get(hookId);
        return cnt != null && cnt.get() >= MAX_HOOK_FAULTS;
    }

    public void recordHookFault(String hookId) {
        if (hookId == null) {
            return;
        }
        anyFaultRecorded = true;
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

    private void readAnimatorScaleNow() {
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
