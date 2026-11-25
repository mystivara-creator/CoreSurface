package org.mystivara.coresurface.engine;

import android.content.Context;
import android.os.Looper;
import android.view.View;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;

/**
 * CoreSurface Native Flagship & Surgical Recents Hook for com.miui.home (HyperOS Launcher).
 *
 * Zero-conflict architecture:
 * - NEVER mutates desktop icon alpha/scale/translation externally (eliminating the inconsistent
 *   jitter caused by fighting MiuiHome's own Folme unlock animator).
 * - Unlocks Xiaomi's NATIVE flagship launcher tier (DeviceLevelUtils, DeviceConfig, CpuLevelUtils,
 *   GpuLevelUtils, DeviceUtils) so HyperOS runs its own native 120 FPS flagship Lockscreen->Home
 *   and App Open/Close animations cleanly.
 * - Applies Zero-FBO Luminous Optical Glass to open folders.
 * - Runs Surgical Recents Guard to prevent black Recent Apps scrims.
 */
public final class LivingFlowHomeHook {
    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final LuminousOverlayEngine luminousEngine;
    private final SurgicalBlurGuardHook blurGuard;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final TelemetryReporter telemetry;

    private volatile boolean contextBootstrapped = false;

    public LivingFlowHomeHook(EngineConfig config, ThermalLodController lodController,
                              LuminousOverlayEngine luminousEngine, SurgicalBlurGuardHook blurGuard,
                              DeviceLevelUnlockHook deviceLevelHook, TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.luminousEngine = luminousEngine;
        this.blurGuard = blurGuard;
        this.deviceLevelHook = deviceLevelHook;
        this.telemetry = telemetry;
    }

    public void install(ClassLoader cl) {
        blurGuard.installWindowToastGuard(cl);
        deviceLevelHook.install(cl);

        try {
            XposedBridge.hookAllMethods(View.class, "onAttachedToWindow", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!isMainThread() || !(param.thisObject instanceof View)) {
                        return;
                    }
                    View view = (View) param.thisObject;
                    bootstrapIfNeeded(view.getContext());
                    inspectHomeView(view);
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
        telemetry.setLastConfig(config.getRawConfig());
        config.addListener(() -> {
            telemetry.setLastConfig(config.getRawConfig());
            luminousEngine.refreshAll();
        });
    }

    private void inspectHomeView(View view) {
        blurGuard.sanitizeRecentsViewIfNeeded(view);

        String cls = view.getClass().getName().toLowerCase();
        if (cls.contains("folder") && (cls.contains("content") || cls.contains("background"))) {
            luminousEngine.decorateView(view, 26.0f);
        }
    }

    private static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }
}
