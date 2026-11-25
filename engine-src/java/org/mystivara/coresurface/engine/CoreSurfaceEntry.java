package org.mystivara.coresurface.engine;

import java.util.concurrent.atomic.AtomicBoolean;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * CoreSurface Zero-FBO Luminous & Native Flagship Engine - LSPosed Entry Point.
 * Strictly scoped to com.android.systemui, com.miui.home, and com.miui.aod
 * (never hooks system_server -> zero bootloop risk).
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

        if (!PKG_SYSTEMUI.equals(pkg) && !PKG_HOME.equals(pkg) && !PKG_AOD.equals(pkg)) {
            return;
        }

        if (!INITIALIZED.compareAndSet(false, true)) {
            return;
        }

        try {
            EngineConfig config = new EngineConfig();
            TelemetryReporter telemetry = new TelemetryReporter(pkg);
            ThermalLodController lodController = new ThermalLodController(config, telemetry);
            SurgicalBlurGuardHook blurGuard = new SurgicalBlurGuardHook(config, telemetry);
            DeviceLevelUnlockHook deviceLevelHook = new DeviceLevelUnlockHook(config, telemetry);

            if (PKG_SYSTEMUI.equals(pkg)) {
                LuminousOverlayEngine luminousEngine = new LuminousOverlayEngine(config, lodController, telemetry);
                new LivingFlowSystemUIHook(config, lodController, luminousEngine, blurGuard, deviceLevelHook, telemetry)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized Zero-FBO Luminous + Native Flagship in com.android.systemui");
            } else if (PKG_HOME.equals(pkg)) {
                LuminousOverlayEngine luminousEngine = new LuminousOverlayEngine(config, lodController, telemetry);
                new LivingFlowHomeHook(config, lodController, luminousEngine, blurGuard, deviceLevelHook, telemetry)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized Native Flagship + RecentsGuard in com.miui.home");
            } else if (PKG_AOD.equals(pkg)) {
                new LivingFlowAodHook(config, lodController, deviceLevelHook, telemetry)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized Native Flagship in com.miui.aod");
            }
        } catch (Throwable t) {
            XposedBridge.log("CoreSurfaceEngine: safe isolation catch in " + pkg + ": " + t);
        }
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
