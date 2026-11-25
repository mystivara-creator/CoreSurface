package org.mystivara.coresurface.engine;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Zero-gimmick live runtime telemetry writer (background daemon thread, zero UI I/O).
 * Reports genuine runtime metrics: hooked native HyperOS gates, hooked Folme/SpringForce
 * methods, tuned spring animations count, guarded Toasts/Recents, and live Thermal LOD.
 */
public final class TelemetryReporter {
    public static final String TELEMETRY_FILENAME = "coresurface_telemetry.prop";

    private final String processName;
    private volatile File cacheDir;
    private volatile String motionProfile = EngineConfig.MOTION_HYPEROS4;
    private volatile String lodTier = "FULL";
    private volatile int thermalStatus = 0;
    private volatile String lastConfig = "default";

    private final Set<String> boundHooks = new LinkedHashSet<>();
    private final AtomicInteger nativeGatesHooked = new AtomicInteger(0);
    private final AtomicInteger folmeHooksBound = new AtomicInteger(0);
    private final AtomicInteger springsTuned = new AtomicInteger(0);
    private final AtomicInteger toastsGuarded = new AtomicInteger(0);
    private final AtomicInteger recentsGuarded = new AtomicInteger(0);

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService ioExecutor = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "CoreSurface-Telemetry");
        t.setDaemon(true);
        t.setPriority(Thread.MIN_PRIORITY);
        return t;
    });
    private volatile boolean flushScheduled = false;

    public TelemetryReporter(String processName) {
        this.processName = processName;
    }

    public void attachContext(Context context) {
        if (context == null) {
            return;
        }
        try {
            Context target = context.getApplicationContext() != null ? context.getApplicationContext() : context;
            File dir = target.getCacheDir();
            if (dir != null) {
                cacheDir = dir;
                scheduleFlush();
            }
        } catch (Throwable ignored) {
        }
    }

    public synchronized void recordHookBound(String hookName) {
        if (hookName != null && !hookName.isEmpty()) {
            boundHooks.add(hookName);
            scheduleFlush();
        }
    }

    public void setMotionProfile(String profile) {
        this.motionProfile = profile != null ? profile : EngineConfig.MOTION_OFF;
        scheduleFlush();
    }

    public void setThermalState(String lodTier, int thermalStatus) {
        this.lodTier = lodTier != null ? lodTier : "FULL";
        this.thermalStatus = thermalStatus;
        scheduleFlush();
    }

    public void setLastConfig(String cfg) {
        this.lastConfig = cfg != null ? cfg : "default";
        scheduleFlush();
    }

    public void addNativeGatesHooked(int delta) {
        if (delta > 0) {
            nativeGatesHooked.addAndGet(delta);
            scheduleFlush();
        }
    }

    public void addFolmeHooksBound(int delta) {
        if (delta > 0) {
            folmeHooksBound.addAndGet(delta);
            scheduleFlush();
        }
    }

    public void incSpringsTuned() {
        springsTuned.incrementAndGet();
        scheduleFlush();
    }

    public void incToastsGuarded() {
        toastsGuarded.incrementAndGet();
        scheduleFlush();
    }

    public void incRecentsGuarded() {
        recentsGuarded.incrementAndGet();
        scheduleFlush();
    }

    public void scheduleFlush() {
        if (cacheDir == null || flushScheduled) {
            return;
        }
        flushScheduled = true;
        mainHandler.postDelayed(() -> ioExecutor.execute(this::flushNow), 600L);
    }

    public void flushNow() {
        flushScheduled = false;
        File dir = cacheDir;
        if (dir == null) {
            return;
        }
        try {
            StringBuilder hooksCsv = new StringBuilder();
            synchronized (this) {
                for (String h : boundHooks) {
                    if (hooksCsv.length() > 0) {
                        hooksCsv.append(',');
                    }
                    hooksCsv.append(h);
                }
            }

            StringBuilder sb = new StringBuilder(256);
            sb.append("ENGINE_ACTIVE=1\n");
            sb.append("ENGINE_VERSION=1.0.0\n");
            sb.append("PROCESS=").append(processName).append('\n');
            sb.append("ENGINE_MODE=NATIVE_MOTION\n");
            sb.append("MOTION_PROFILE=").append(motionProfile).append('\n');
            sb.append("LOD_TIER=").append(lodTier).append('\n');
            sb.append("THERMAL_STATUS=").append(thermalStatus).append('\n');
            sb.append("HOOKS_BOUND=").append(hooksCsv).append('\n');
            sb.append("NATIVE_GATES=").append(nativeGatesHooked.get()).append('\n');
            sb.append("FOLME_HOOKS=").append(folmeHooksBound.get()).append('\n');
            sb.append("SPRINGS_TUNED=").append(springsTuned.get()).append('\n');
            sb.append("TOASTS_GUARDED=").append(toastsGuarded.get()).append('\n');
            sb.append("RECENTS_GUARDED=").append(recentsGuarded.get()).append('\n');
            sb.append("LAST_CONFIG=").append(lastConfig).append('\n');
            sb.append("UPDATED_MS=").append(System.currentTimeMillis()).append('\n');

            File tmp = new File(dir, TELEMETRY_FILENAME + ".tmp");
            File dst = new File(dir, TELEMETRY_FILENAME);
            try (FileOutputStream fos = new FileOutputStream(tmp)) {
                fos.write(sb.toString().getBytes(StandardCharsets.UTF_8));
                fos.flush();
            }
            if (!tmp.renameTo(dst)) {
                try (FileOutputStream fos = new FileOutputStream(dst)) {
                    fos.write(sb.toString().getBytes(StandardCharsets.UTF_8));
                }
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        } catch (Throwable ignored) {
        }
    }
}
