package org.mystivara.coresurface.engine;

import android.app.Application;
import android.content.Context;
import android.view.View;

import java.util.concurrent.atomic.AtomicBoolean;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * CoreSurface Pure Flagship Motion & Device Bug Guard Engine - LSPosed Entry Point.
 *
 * Default scope: com.android.systemui, com.miui.home, com.miui.aod, com.android.settings.
 * Any additional user-enabled UI app in LSPosed automatically receives the unified
 * analytical SpringPhysicsCurve (iOS/ColorOS 17 or HyperOS 4) with DeviceBugGuard
 * circuit-breaker safety.
 *
 * Hard-blocklisted (NEVER hooked -> zero bootloop risk):
 *   android, system_server, com.android.phone, com.android.providers.*, com.android.bluetooth
 */
public final class CoreSurfaceEntry implements IXposedHookLoadPackage {
    private static final String SELF_PKG = "org.mystivara.coresurface.engine";
    private static final String PKG_SYSTEMUI = "com.android.systemui";
    private static final String PKG_HOME = "com.miui.home";
    private static final String PKG_AOD = "com.miui.aod";

    private static final AtomicBoolean INITIALIZED = new AtomicBoolean(false);

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        if (lpparam == null || lpparam.packageName == null) {
            return;
        }
        String pkg = lpparam.packageName;

        if (SELF_PKG.equals(pkg)) {
            hookSelfStatus(lpparam.classLoader);
            return;
        }

        if (isSystemCriticalBlocked(pkg)) {
            return;
        }

        if (!INITIALIZED.compareAndSet(false, true)) {
            return;
        }

        try {
            EngineConfig config = new EngineConfig();
            TelemetryReporter telemetry = new TelemetryReporter(pkg);
            ThermalLodController lodController = new ThermalLodController(config, telemetry);
            DeviceBugGuard bugGuard = new DeviceBugGuard(telemetry);
            SurgicalBlurGuardHook blurGuard = new SurgicalBlurGuardHook(config, telemetry);
            DeviceLevelUnlockHook deviceLevelHook = new DeviceLevelUnlockHook(config, telemetry);
            FolmePhysicsHook folmeHook = new FolmePhysicsHook(config, lodController, bugGuard, telemetry);

            if (PKG_SYSTEMUI.equals(pkg)) {
                new LivingFlowSystemUIHook(config, lodController, bugGuard, folmeHook, blurGuard, deviceLevelHook, telemetry)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized Universal Motion + BugGuard in com.android.systemui");
            } else if (PKG_HOME.equals(pkg)) {
                new LivingFlowHomeHook(config, lodController, bugGuard, folmeHook, blurGuard, deviceLevelHook, telemetry)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized Universal Motion + RecentsGuard in com.miui.home");
            } else if (PKG_AOD.equals(pkg)) {
                new LivingFlowAodHook(config, lodController, bugGuard, folmeHook, deviceLevelHook, telemetry)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized Motion + Non-LTPO AOD Unlock in com.miui.aod");
            } else {
                // Settings & any additional user-scoped UI app: universal SpringPhysicsCurve + BugGuard
                installUniversalUiApp(lpparam.classLoader, config, lodController, bugGuard, folmeHook, telemetry);
                XposedBridge.log("CoreSurfaceEngine: initialized Universal UI SpringPhysicsCurve in " + pkg);
            }
        } catch (Throwable t) {
            XposedBridge.log("CoreSurfaceEngine: safe isolation catch in " + pkg + ": " + t);
        }
    }

    private void installUniversalUiApp(ClassLoader cl, final EngineConfig config,
                                       final ThermalLodController lodController,
                                       final DeviceBugGuard bugGuard,
                                       final FolmePhysicsHook folmeHook,
                                       final TelemetryReporter telemetry) {
        folmeHook.install(cl);
        final AtomicBoolean bootstrapped = new AtomicBoolean(false);

        XC_MethodHook bootHook = new XC_MethodHook() {
            @Override
            protected void afterHookedMethod(MethodHookParam param) {
                if (bootstrapped.get()) {
                    return;
                }
                Context ctx = null;
                if (param.thisObject instanceof Context) {
                    ctx = (Context) param.thisObject;
                } else if (param.thisObject instanceof View) {
                    ctx = ((View) param.thisObject).getContext();
                }
                if (ctx == null || !bootstrapped.compareAndSet(false, true)) {
                    return;
                }
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
        };

        try {
            XposedBridge.hookAllMethods(Application.class, "onCreate", bootHook);
        } catch (Throwable ignored) {
        }
        try {
            XposedBridge.hookAllMethods(View.class, "onAttachedToWindow", bootHook);
        } catch (Throwable ignored) {
        }
    }

    private static boolean isSystemCriticalBlocked(String pkg) {
        return "android".equals(pkg)
                || "system".equals(pkg)
                || "system_server".equals(pkg)
                || "com.android.phone".equals(pkg)
                || "com.android.bluetooth".equals(pkg)
                || "com.android.nfc".equals(pkg)
                || pkg.startsWith("com.android.providers.");
    }

    private void hookSelfStatus(ClassLoader cl) {
        try {
            XposedHelpers.findAndHookMethod(
                    "org.mystivara.coresurface.engine.EngineStatusActivity",
                    cl,
                    "isModuleActive",
                    new XC_MethodHook() {
                        @Override
                        protected void beforeHookedMethod(MethodHookParam param) {
                            param.setResult(Boolean.TRUE);
                        }
                    });
        } catch (Throwable ignored) {
        }
    }
}
