package org.mystivara.coresurface.engine;

import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;

import java.util.concurrent.CopyOnWriteArrayList;

/**
 * CoreSurface Exclusive: Thermal-Adaptive Motion Safety Controller.
 * Uses Android's official user-space PowerManager thermal status listener
 * (zero kernel/sysfs coupling) to smoothly tighten Folme/SpringForce motion curves
 * when the phone warms up, keeping 120 FPS responsive without stutter.
 */
public final class ThermalLodController {
    public static final float LOD_FULL = 1.0f;
    public static final float LOD_BALANCED = 0.6f;
    public static final float LOD_ECO = 0.25f;

    private final EngineConfig config;
    private final TelemetryReporter telemetry;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final CopyOnWriteArrayList<Runnable> listeners = new CopyOnWriteArrayList<>();

    private volatile int thermalStatus = PowerManager.THERMAL_STATUS_NONE;
    private volatile boolean attached = false;

    public ThermalLodController(EngineConfig config, TelemetryReporter telemetry) {
        this.config = config;
        this.telemetry = telemetry;
        this.config.addListener(() -> telemetry.setThermalState(getTierName(), thermalStatus));
    }

    public void addListener(Runnable listener) {
        if (listener != null) {
            listeners.addIfAbsent(listener);
        }
    }

    public void attachContext(Context context) {
        if (context == null || attached || Build.VERSION.SDK_INT < 29) {
            return;
        }
        attached = true;
        try {
            Context appCtx = context.getApplicationContext() != null ? context.getApplicationContext() : context;
            PowerManager pm = (PowerManager) appCtx.getSystemService(Context.POWER_SERVICE);
            if (pm == null) {
                return;
            }
            updateStatus(pm.getCurrentThermalStatus());
            pm.addThermalStatusListener(this::updateStatus);
        } catch (Throwable ignored) {
        }
    }

    private void updateStatus(int status) {
        if (thermalStatus == status && attached) {
            telemetry.setThermalState(getTierName(), status);
            return;
        }
        thermalStatus = status;
        telemetry.setThermalState(getTierName(), status);
        // Dispatch UI shader LOD refresh strictly on the main thread
        mainHandler.post(() -> {
            for (Runnable r : listeners) {
                try {
                    r.run();
                } catch (Throwable ignored) {
                }
            }
        });
    }

    public float getEffectiveLod() {
        if (!config.isThermalLod()) {
            return LOD_FULL;
        }
        if (thermalStatus >= PowerManager.THERMAL_STATUS_SEVERE) {
            return LOD_ECO;
        }
        if (thermalStatus >= PowerManager.THERMAL_STATUS_MODERATE) {
            return LOD_BALANCED;
        }
        return LOD_FULL;
    }

    public String getTierName() {
        if (!config.isThermalLod()) {
            return "FULL_FIXED";
        }
        if (thermalStatus >= PowerManager.THERMAL_STATUS_SEVERE) {
            return "ECO";
        }
        if (thermalStatus >= PowerManager.THERMAL_STATUS_MODERATE) {
            return "BALANCED";
        }
        return "FULL";
    }

    public int getThermalStatus() {
        return thermalStatus;
    }
}
