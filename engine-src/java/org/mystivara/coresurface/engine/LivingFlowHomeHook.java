package org.mystivara.coresurface.engine;

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
 * - Refines Xiaomi's native 60/90/120 Hz Folme & SpringForce curves via FolmePhysicsHook.
 * - Runs fast class-cached Surgical Recents Guard with DeviceBugGuard circuit breakers.
 */
public final class LivingFlowHomeHook {
    private final ProcessBootstrap bootstrap;
    private final DeviceBugGuard bugGuard;
    private final FolmePhysicsHook folmeHook;
    private final SurgicalBlurGuardHook blurGuard;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final TelemetryReporter telemetry;

    public LivingFlowHomeHook(ProcessBootstrap bootstrap, DeviceBugGuard bugGuard,
                              FolmePhysicsHook folmeHook, SurgicalBlurGuardHook blurGuard,
                              DeviceLevelUnlockHook deviceLevelHook, TelemetryReporter telemetry) {
        this.bootstrap = bootstrap;
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
        bootstrap.install();

        try {
            XposedBridge.hookAllMethods(View.class, "onAttachedToWindow", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("HomeRecentsAttach")
                            || !isMainThread() || !(param.thisObject instanceof View)) {
                        return;
                    }
                    try {
                        View view = (View) param.thisObject;
                        if (blurGuard.isRecentsClass(view.getClass())) {
                            blurGuard.sanitizeRecentsViewIfNeeded(view);
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("HomeRecentsAttach");
                    }
                }
            });

            XposedBridge.hookAllMethods(View.class, "onVisibilityChanged", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("HomeRecentsVis")
                            || !isMainThread() || !(param.thisObject instanceof View)) {
                        return;
                    }
                    try {
                        View view = (View) param.thisObject;
                        if (blurGuard.isRecentsClass(view.getClass())) {
                            blurGuard.sanitizeRecentsViewIfNeeded(view);
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("HomeRecentsVis");
                    }
                }
            });

            telemetry.recordHookBound("RecentsGuard");
        } catch (Throwable ignored) {
        }
    }

    private static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }
}
