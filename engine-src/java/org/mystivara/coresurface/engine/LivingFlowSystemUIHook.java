package org.mystivara.coresurface.engine;

import android.app.Application;
import android.content.Context;
import android.view.View;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;

/**
 * CoreSurface Pure Flagship Motion & Experience Hook for com.android.systemui.
 *
 * Preserves 100% original HyperOS visual appearance:
 * - ZERO custom glass drawables, overlays, FBO shaders, or touch-event hooks.
 * - Unlocks Xiaomi's native flagship tier via DeviceLevelUnlockHook.
 * - Refines Xiaomi's native 120 Hz Folme & Jetpack SpringForce curves via FolmePhysicsHook
 *   (HyperOS 4 Flagship or iOS / ColorOS 17 Silk Fluid, hot-switchable without reboot).
 * - Strips broken HyperOS 3 Toast window blur via SurgicalBlurGuardHook.
 */
public final class LivingFlowSystemUIHook {
    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final DeviceBugGuard bugGuard;
    private final FolmePhysicsHook folmeHook;
    private final SurgicalBlurGuardHook blurGuard;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final TelemetryReporter telemetry;

    private volatile boolean contextBootstrapped = false;

    public LivingFlowSystemUIHook(EngineConfig config, ThermalLodController lodController,
                                  DeviceBugGuard bugGuard, FolmePhysicsHook folmeHook,
                                  SurgicalBlurGuardHook blurGuard, DeviceLevelUnlockHook deviceLevelHook,
                                  TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.bugGuard = bugGuard;
        this.folmeHook = folmeHook;
        this.blurGuard = blurGuard;
        this.deviceLevelHook = deviceLevelHook;
        this.telemetry = telemetry;
    }

    public void install(ClassLoader cl) {
        blurGuard.installWindowToastGuard(cl);
        deviceLevelHook.install(cl);
        folmeHook.install(cl);

        installContextBootstrap();
    }

    private void installContextBootstrap() {
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
        bugGuard.attachContext(appCtx);
        folmeHook.attachContext(appCtx);
        telemetry.setMotionProfile(config.getMotionProfile());
        telemetry.setLastConfig(config.getRawConfig());
        config.addListener(() -> {
            telemetry.setMotionProfile(config.getMotionProfile());
            telemetry.setLastConfig(config.getRawConfig());
        });
    }
}
