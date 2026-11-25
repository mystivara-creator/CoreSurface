package org.mystivara.coresurface.engine;

import android.content.Context;
import android.os.Looper;
import android.view.View;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;

/**
 * CoreSurface Native Flagship Hook for com.miui.aod.
 * Unlocks native high-tier device level inside MiuiAod without touching HyperOS 3's
 * unstable mFullAodHideEase private field.
 */
public final class LivingFlowAodHook {
    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final TelemetryReporter telemetry;
    private volatile boolean contextBootstrapped = false;

    public LivingFlowAodHook(EngineConfig config, ThermalLodController lodController,
                             DeviceLevelUnlockHook deviceLevelHook, TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.deviceLevelHook = deviceLevelHook;
        this.telemetry = telemetry;
    }

    public void install(ClassLoader cl) {
        deviceLevelHook.install(cl);
        try {
            XposedBridge.hookAllMethods(View.class, "onAttachedToWindow", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!isMainThread() || !(param.thisObject instanceof View)) {
                        return;
                    }
                    bootstrapIfNeeded(((View) param.thisObject).getContext());
                }
            });
            telemetry.recordHookBound("AodFlagshipTier");
        } catch (Throwable ignored) {
        }
    }

    private void bootstrapIfNeeded(Context ctx) {
        if (contextBootstrapped || ctx == null) {
            return;
        }
        contextBootstrapped = true;
        config.attachContext(ctx);
        telemetry.attachContext(ctx);
        lodController.attachContext(ctx);
        telemetry.setLastConfig(config.getRawConfig());
        config.addListener(() -> telemetry.setLastConfig(config.getRawConfig()));
    }

    private static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }
}
