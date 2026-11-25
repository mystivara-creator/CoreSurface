package org.mystivara.coresurface.engine;

import android.app.Application;
import android.content.Context;
import android.os.Looper;
import android.view.View;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;

/**
 * CoreSurface Pure Flagship Motion & Surgical Recents Hook for com.miui.home (HyperOS Launcher).
 *
 * Zero-conflict, 100% original UI architecture:
 * - NEVER mutates desktop icon alpha/scale/translation externally and NEVER attaches custom
 *   glass overlays to folders (preserves 100% authentic HyperOS Launcher visuals).
 * - Unlocks Xiaomi's native flagship launcher tier via DeviceLevelUnlockHook.
 * - Refines Xiaomi's native 120 Hz Folme & SpringForce curves via FolmePhysicsHook
 *   (HyperOS 4 Flagship or iOS / ColorOS 17 Silk Fluid).
 * - Runs fast class-cached Surgical Recents Guard to prevent black Recent Apps scrims.
 */
public final class LivingFlowHomeHook {
    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final DeviceBugGuard bugGuard;
    private final FolmePhysicsHook folmeHook;
    private final SurgicalBlurGuardHook blurGuard;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final TelemetryReporter telemetry;

    private volatile boolean contextBootstrapped = false;

    public LivingFlowHomeHook(EngineConfig config, ThermalLodController lodController,
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
        blurGuard.installHomeRecentsGuard(cl);
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
                    if (!(param.thisObject instanceof View)) {
                        return;
                    }
                    View view = (View) param.thisObject;
                    if (!contextBootstrapped) {
                        bootstrapIfNeeded(view.getContext());
                    }
                    if (isMainThread() && blurGuard.isRecentsClass(view.getClass())) {
                        blurGuard.sanitizeRecentsViewIfNeeded(view);
                    }
                }
            });

            XposedBridge.hookAllMethods(View.class, "onVisibilityChanged", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!isMainThread() || !(param.thisObject instanceof View)) {
                        return;
                    }
                    View view = (View) param.thisObject;
                    if (blurGuard.isRecentsClass(view.getClass())) {
                        blurGuard.sanitizeRecentsViewIfNeeded(view);
                    }
                }
            });

            telemetry.recordHookBound("RecentsGuard");
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

    private static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }
}
