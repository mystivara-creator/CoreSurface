package org.mystivara.coresurface.engine;

import android.os.Looper;
import android.view.View;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * CoreSurface Pure Flagship Motion & Surgical Recents Hook for com.miui.home (HyperOS Launcher).
 *
 * Ultra-lightweight, 100% original UI architecture:
 * - ZERO global View.onAttachedToWindow / onVisibilityChanged hooks (hooks ONLY Recents
 *   container classes so icons, folders, widgets, and workspace scrolls incur 0 hook overhead).
 * - Unlocks Xiaomi's native flagship launcher tier via DeviceLevelUnlockHook.
 * - Refines Xiaomi's native 60/90/120/144 Hz Folme & SpringForce curves via FolmePhysicsHook.
 * - Runs Surgical Recents Guard with DeviceBugGuard circuit breakers.
 */
public final class LivingFlowHomeHook {
    private static final String[] RECENTS_VIEW_CLASSES = new String[] {
            "com.miui.home.recents.views.RecentsContainer",
            "com.miui.home.recents.views.RecentsView",
            "com.miui.home.recents.NavStubView"
    };

    private final ProcessBootstrap bootstrap;
    private final DeviceBugGuard bugGuard;
    private final FolmePhysicsHook folmeHook;
    private final SurgicalBlurGuardHook blurGuard;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final LauncherChoreographyHook launcherChoreo;
    private final TelemetryReporter telemetry;

    public LivingFlowHomeHook(ProcessBootstrap bootstrap, DeviceBugGuard bugGuard,
                              FolmePhysicsHook folmeHook, SurgicalBlurGuardHook blurGuard,
                              DeviceLevelUnlockHook deviceLevelHook,
                              LauncherChoreographyHook launcherChoreo,
                              TelemetryReporter telemetry) {
        this.bootstrap = bootstrap;
        this.bugGuard = bugGuard;
        this.folmeHook = folmeHook;
        this.blurGuard = blurGuard;
        this.deviceLevelHook = deviceLevelHook;
        this.launcherChoreo = launcherChoreo;
        this.telemetry = telemetry;
    }

    public void install(ClassLoader cl) {
        // Unified WindowManagerGlobal guard (Toast + Recents + -1 Screen) installed in a single trampoline
        blurGuard.installHomeRecentsGuard(cl);
        deviceLevelHook.install(cl);
        folmeHook.install(cl);
        launcherChoreo.install(cl);
        bootstrap.install();

        XC_MethodHook sanitizeHook = new XC_MethodHook() {
            @Override
            protected void afterHookedMethod(MethodHookParam param) {
                if (bugGuard.isHookTripped("HomeRecentsSanitize")
                        || !isMainThread() || !(param.thisObject instanceof View)) {
                    return;
                }
                try {
                    blurGuard.sanitizeRecentsViewIfNeeded((View) param.thisObject);
                } catch (Throwable ignored) {
                    bugGuard.recordHookFault("HomeRecentsSanitize");
                }
            }
        };

        int hookedTargets = 0;
        for (String clsName : RECENTS_VIEW_CLASSES) {
            try {
                Class<?> cls = XposedHelpers.findClassIfExists(clsName, cl);
                if (cls == null) {
                    continue;
                }
                XposedBridge.hookAllMethods(cls, "onAttachedToWindow", sanitizeHook);
                XposedBridge.hookAllMethods(cls, "onVisibilityChanged", sanitizeHook);
                hookedTargets++;
            } catch (Throwable ignored) {
            }
        }
        if (hookedTargets > 0) {
            telemetry.recordHookBound("RecentsGuard");
        }
    }

    private static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }
}
