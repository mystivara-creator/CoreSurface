package org.mystivara.coresurface.engine;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Zero-gimmick live runtime telemetry writer (background daemon thread, zero UI I/O).
 * Uses atomic two-tier flush throttling (500ms fast escalation for state changes, 5000ms
 * lazy flush for high-frequency counters) and stamps kernel BOOT_ID so verifier.sh never
 * mistakes stale cache files from a prior boot for an active LSPosed hook.
 */
public final class TelemetryReporter {
    public static final String TELEMETRY_FILENAME = "coresurface_telemetry.prop";
    private static final long FAST_FLUSH_MS = 500L;
    private static final long LAZY_FLUSH_MS = 15000L;

    private final String processName;
    private final String bootId;
    private volatile File cacheDir;
    private volatile String motionProfile = EngineConfig.MOTION_HYPEROS4;
    private volatile int displayHz = 60;
    private volatile String lodTier = "FULL";
    private volatile int thermalStatus = 0;
    private volatile String lastConfig = "default";

    private final Set<String> boundHooks = new LinkedHashSet<>();
    private final Set<String> mitigatedBugs = new LinkedHashSet<>();
    private final AtomicInteger nativeGatesHooked = new AtomicInteger(0);
    private final AtomicInteger folmeHooksBound = new AtomicInteger(0);
    private final AtomicInteger aodGatesHooked = new AtomicInteger(0);
    private final AtomicInteger springsTuned = new AtomicInteger(0);
    private final AtomicInteger curvesApplied = new AtomicInteger(0);
    private final AtomicInteger toastsGuarded = new AtomicInteger(0);
    private final AtomicInteger recentsGuarded = new AtomicInteger(0);
    private final AtomicInteger circuitTrips = new AtomicInteger(0);

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService ioExecutor = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "CoreSurface-Telemetry");
        t.setDaemon(true);
        t.setPriority(Thread.MIN_PRIORITY);
        return t;
    });

    private final AtomicBoolean flushScheduled = new AtomicBoolean(false);
    private final AtomicBoolean fastScheduled = new AtomicBoolean(false);
    private final Runnable flushTask = () -> ioExecutor.execute(this::flushNow);

    public TelemetryReporter(String processName) {
        this.processName = processName;
        this.bootId = readBootId();
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
                scheduleFlush(true);
            }
        } catch (Throwable ignored) {
        }
    }

    public synchronized void recordHookBound(String hookName) {
        if (hookName != null && !hookName.isEmpty() && boundHooks.add(hookName)) {
            scheduleFlush(true);
        }
    }

    public synchronized void recordOsBugMitigated(String bugId) {
        if (bugId != null && !bugId.isEmpty() && mitigatedBugs.add(bugId)) {
            scheduleFlush(true);
        }
    }

    public void setMotionProfile(String profile) {
        String next = profile != null ? profile : EngineConfig.MOTION_OFF;
        if (!next.equals(this.motionProfile)) {
            this.motionProfile = next;
            scheduleFlush(true);
        }
    }

    public void setDisplayHz(int hz) {
        if (hz > 0 && hz != this.displayHz) {
            this.displayHz = hz;
            scheduleFlush(true);
        }
    }

    public void setThermalState(String lodTier, int thermalStatus) {
        String nextTier = lodTier != null ? lodTier : "FULL";
        if (!nextTier.equals(this.lodTier) || thermalStatus != this.thermalStatus) {
            this.lodTier = nextTier;
            this.thermalStatus = thermalStatus;
            scheduleFlush(true);
        }
    }

    public void setLastConfig(String cfg) {
        String next = cfg != null ? cfg : "default";
        if (!next.equals(this.lastConfig)) {
            this.lastConfig = next;
            scheduleFlush(true);
        }
    }

    public void addNativeGatesHooked(int delta) {
        if (delta > 0) {
            nativeGatesHooked.addAndGet(delta);
            scheduleFlush(true);
        }
    }

    public void addFolmeHooksBound(int delta) {
        if (delta > 0) {
            folmeHooksBound.addAndGet(delta);
            scheduleFlush(true);
        }
    }

    public void addAodGatesHooked(int delta) {
        if (delta > 0) {
            aodGatesHooked.addAndGet(delta);
            scheduleFlush(true);
        }
    }

    public void incSpringsTuned() {
        springsTuned.incrementAndGet();
        scheduleFlush(false);
    }

    public void incCurvesApplied() {
        curvesApplied.incrementAndGet();
        scheduleFlush(false);
    }

    public void incToastsGuarded() {
        toastsGuarded.incrementAndGet();
        scheduleFlush(false);
    }

    public void incRecentsGuarded() {
        recentsGuarded.incrementAndGet();
        scheduleFlush(false);
    }

    public void incCircuitTrips() {
        circuitTrips.incrementAndGet();
        scheduleFlush(true);
    }

    public void scheduleFlush() {
        scheduleFlush(true);
    }

    private void scheduleFlush(boolean fast) {
        if (cacheDir == null) {
            return;
        }
        if (fast) {
            // Escalate a pending 5s lazy flush to 500ms when state changes
            if (fastScheduled.compareAndSet(false, true)) {
                flushScheduled.set(true);
                mainHandler.removeCallbacks(flushTask);
                mainHandler.postDelayed(flushTask, FAST_FLUSH_MS);
            }
            return;
        }
        if (flushScheduled.compareAndSet(false, true)) {
            mainHandler.postDelayed(flushTask, LAZY_FLUSH_MS);
        }
    }

    public void flushNow() {
        flushScheduled.set(false);
        fastScheduled.set(false);
        File dir = cacheDir;
        if (dir == null) {
            return;
        }
        try {
            StringBuilder hooksCsv = new StringBuilder();
            StringBuilder bugsCsv = new StringBuilder();
            synchronized (this) {
                for (String h : boundHooks) {
                    if (hooksCsv.length() > 0) {
                        hooksCsv.append(',');
                    }
                    hooksCsv.append(h);
                }
                for (String b : mitigatedBugs) {
                    if (bugsCsv.length() > 0) {
                        bugsCsv.append(',');
                    }
                    bugsCsv.append(b);
                }
            }

            StringBuilder sb = new StringBuilder(420);
            sb.append("ENGINE_ACTIVE=1\n");
            sb.append("ENGINE_VERSION=1.0.0\n");
            if (!bootId.isEmpty()) {
                sb.append("BOOT_ID=").append(bootId).append('\n');
            }
            sb.append("PROCESS=").append(processName).append('\n');
            sb.append("ENGINE_MODE=NATIVE_MOTION\n");
            sb.append("MOTION_PROFILE=").append(motionProfile).append('\n');
            sb.append("DISPLAY_HZ=").append(displayHz).append('\n');
            sb.append("LOD_TIER=").append(lodTier).append('\n');
            sb.append("THERMAL_STATUS=").append(thermalStatus).append('\n');
            sb.append("HOOKS_BOUND=").append(hooksCsv).append('\n');
            sb.append("BUGS_MITIGATED=").append(bugsCsv).append('\n');
            sb.append("NATIVE_GATES=").append(nativeGatesHooked.get()).append('\n');
            sb.append("FOLME_HOOKS=").append(folmeHooksBound.get()).append('\n');
            sb.append("AOD_GATES=").append(aodGatesHooked.get()).append('\n');
            sb.append("SPRINGS_TUNED=").append(springsTuned.get()).append('\n');
            sb.append("CURVES_APPLIED=").append(curvesApplied.get()).append('\n');
            sb.append("TOASTS_GUARDED=").append(toastsGuarded.get()).append('\n');
            sb.append("RECENTS_GUARDED=").append(recentsGuarded.get()).append('\n');
            sb.append("CIRCUIT_TRIPS=").append(circuitTrips.get()).append('\n');
            sb.append("LAST_CONFIG=").append(lastConfig).append('\n');
            sb.append("UPDATED_MS=").append(System.currentTimeMillis()).append('\n');

            File tmp = new File(dir, TELEMETRY_FILENAME + ".tmp");
            File dst = new File(dir, TELEMETRY_FILENAME);
            byte[] payload = sb.toString().getBytes(StandardCharsets.UTF_8);
            try (FileOutputStream fos = new FileOutputStream(tmp)) {
                fos.write(payload);
                fos.flush();
            }
            if (!tmp.renameTo(dst)) {
                try (FileOutputStream fos = new FileOutputStream(dst)) {
                    fos.write(payload);
                }
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        } catch (Throwable ignored) {
        }
    }

    private static String readBootId() {
        try (BufferedReader br = new BufferedReader(
                new InputStreamReader(new FileInputStream("/proc/sys/kernel/random/boot_id"), StandardCharsets.UTF_8))) {
            String line = br.readLine();
            return line != null ? line.trim() : "";
        } catch (Throwable ignored) {
            return "";
        }
    }
}
