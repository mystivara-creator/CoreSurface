package org.mystivara.coresurface.engine;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * CoreSurface Luminous & LivingFlow Engine - LSPosed Entry Point.
 * Strictly scoped to com.android.systemui, com.miui.home, and com.miui.aod
 * (never hooks system_server -> zero bootloop risk).
 */
public final class CoreSurfaceEntry implements IXposedHookLoadPackage {
    private static final String SELF_PKG = "org.mystivara.coresurface.engine";
    private static final String PKG_SYSTEMUI = "com.android.systemui";
    private static final String PKG_HOME = "com.miui.home";
    private static final String PKG_AOD = "com.miui.aod";

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

        try {
            EngineConfig config = new EngineConfig();
            TelemetryReporter telemetry = new TelemetryReporter(pkg);
            ThermalLodController lodController = new ThermalLodController(config, telemetry);
            SurgicalBlurGuardHook blurGuard = new SurgicalBlurGuardHook(config, telemetry);

            if (PKG_SYSTEMUI.equals(pkg)) {
                LuminousShaderEngine shaderEngine = new LuminousShaderEngine(config, lodController, telemetry);
                new LivingFlowSystemUIHook(config, lodController, shaderEngine, blurGuard, telemetry)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized in com.android.systemui");
            } else if (PKG_HOME.equals(pkg)) {
                LuminousShaderEngine shaderEngine = new LuminousShaderEngine(config, lodController, telemetry);
                new LivingFlowHomeHook(config, lodController, shaderEngine, blurGuard, telemetry)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized in com.miui.home");
            } else if (PKG_AOD.equals(pkg)) {
                new LivingFlowAodHook(config, lodController, telemetry).install();
                XposedBridge.log("CoreSurfaceEngine: initialized in com.miui.aod");
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
