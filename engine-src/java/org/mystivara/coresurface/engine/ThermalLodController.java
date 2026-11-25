package org.mystivara.coresurface.engine;

import android.content.Context;
import android.os.Build;
import android.os.PowerManager;

/**
 * CoreSurface Exclusive: Thermal-Adaptive Visual LOD Controller.
 * Uses Android's official user-space PowerManager thermal status listener
 * (zero kernel/sysfs coupling) to smoothly scale AGSL optical shader complexity
 * when the phone warms up, keeping 120 FPS responsive without stutter.
 */
public final class ThermalLodController {
    public static final float LOD_FULL = 1.0f;
    public static final float LOD_BALANCED = 0.6f;
    public static final float LOD_ECO = 0.25f;

    private final EngineConfig config;
    private final TelemetryReporter telemetry;
    private volatile int thermalStatus = PowerManager.THERMAL_STATUS_NONE;
    private volatile boolean attached = false;

    public ThermalLodController(EngineConfig config, TelemetryReporter telemetry) {
        this.config = config;
        this.telemetry = telemetry;
    }

    public void attachContext(Context context) {
        if (context == null || attached || Build.VERSION.SDK_INT < 29) {
            return;
        }
        attached = true;
        try {
            PowerManager pm = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
            if (pm == null) {
                return;
            }
            updateStatus(pm.getCurrentThermalStatus());
            pm.addThermalStatusListener(this::updateStatus);
        } catch (Throwable ignored) {
        }
    }

    private void updateStatus(int status) {
        thermalStatus = status;
        telemetry.setThermalState(getTierName(), status);
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
