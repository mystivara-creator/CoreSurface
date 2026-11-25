package org.mystivara.coresurface.engine;

import android.app.Application;
import android.content.Context;
import android.view.View;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;

/**
 * CoreSurface Native Flagship & Motion Hook for com.miui.aod.
 * Unlocks native high-tier device level and tunes native Folme springs inside MiuiAod
 * without touching HyperOS 3's unstable mFullAodHideEase private field.
 */
public final class LivingFlowAodHook {
    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final FolmePhysicsHook folmeHook;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final TelemetryReporter telemetry;
    private volatile boolean contextBootstrapped = false;

    public LivingFlowAodHook(EngineConfig config, ThermalLodController lodController,
                             FolmePhysicsHook folmeHook, DeviceLevelUnlockHook deviceLevelHook,
                             TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.folmeHook = folmeHook;
        this.deviceLevelHook = deviceLevelHook;
        this.telemetry = telemetry;
    }

    public void install(ClassLoader cl) {
        deviceLevelHook.install(cl);
        folmeHook.install(cl);

        try {
            XposedBridge.hookAllMethods(Application.class, "onCreate", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (contextBootstrapped || !(param.thisObject instanceof Context)) {
                        return;
                    }
                    bootstrapIfNeeded((Context) param.thisObject);
                }
            });
        } catch (Throwable ignored) {
        }

        try {
            XposedBridge.hookAllMethods(View.class, "onAttachedToWindow", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (contextBootstrapped || !(param.thisObject instanceof View)) {
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
        Context appCtx = ctx.getApplicationContext() != null ? ctx.getApplicationContext() : ctx;
        config.attachContext(appCtx);
        telemetry.attachContext(appCtx);
        lodController.attachContext(appCtx);
        telemetry.setMotionProfile(config.getMotionProfile());
        telemetry.setLastConfig(config.getRawConfig());
        config.addListener(() -> {
            telemetry.setMotionProfile(config.getMotionProfile());
            telemetry.setLastConfig(config.getRawConfig());
        });
    }
}
