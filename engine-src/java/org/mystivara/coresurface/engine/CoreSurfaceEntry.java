package org.mystivara.coresurface.engine;

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
 * circuit-breaker safety and self-unhooking ProcessBootstrap.
 *
 * Hard-blocklisted (NEVER hooked -> zero bootloop risk):
 *   android, system_server, com.android.phone, com.android.providers.*, com.android.bluetooth, com.android.nfc
 */
public final class CoreSurfaceEntry implements IXposedHookLoadPackage {
    private static final String SELF_PKG = "org.mystivara.coresurface.engine";
    private static final String PKG_SYSTEMUI = "com.android.systemui";
    private static final String PKG_HOME = "com.miui.home";
    private static final String PKG_POCO_HOME = "com.mi.android.globallauncher";
    private static final String PKG_GLOBAL_MINUS_ONE = "com.mi.android.globalminusscreen";
    private static final String PKG_CN_MINUS_ONE = "com.miui.personalassistant";
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
            SurgicalBlurGuardHook blurGuard = new SurgicalBlurGuardHook(config, bugGuard, telemetry);
            DeviceLevelUnlockHook deviceLevelHook = new DeviceLevelUnlockHook(config, bugGuard, telemetry);
            FolmePhysicsHook folmeHook = new FolmePhysicsHook(config, lodController, bugGuard, telemetry);
            ProcessBootstrap bootstrap = new ProcessBootstrap(config, telemetry, lodController, bugGuard, folmeHook);

            if (PKG_SYSTEMUI.equals(pkg)) {
                CoreSurfaceChoreographer choreo = new CoreSurfaceChoreographer(telemetry);
                ShellTransitionPhysicsEngine shellEngine = new ShellTransitionPhysicsEngine(folmeHook, bugGuard, telemetry);
                SystemUIChoreographyHook sysUiChoreo = new SystemUIChoreographyHook(folmeHook, choreo, bugGuard, telemetry);
                new LivingFlowSystemUIHook(bootstrap, folmeHook, blurGuard, deviceLevelHook, shellEngine, sysUiChoreo)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized True Physics (WMShell + Shade + Folme) in com.android.systemui");
            } else if (PKG_HOME.equals(pkg) || PKG_POCO_HOME.equals(pkg)) {
                CoreSurfaceChoreographer choreo = new CoreSurfaceChoreographer(telemetry);
                LauncherChoreographyHook launcherChoreo = new LauncherChoreographyHook(folmeHook, choreo, bugGuard, telemetry);
                new LivingFlowHomeHook(bootstrap, bugGuard, folmeHook, blurGuard, deviceLevelHook, launcherChoreo, telemetry)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized True Physics (RectF + Folder + RecentsGuard) in " + pkg);
            } else if (PKG_GLOBAL_MINUS_ONE.equals(pkg) || PKG_CN_MINUS_ONE.equals(pkg)) {
                blurGuard.installMinusOneAppGuard(lpparam.classLoader);
                bootstrap.install();
                XposedBridge.log("CoreSurfaceEngine: initialized -1 Screen (App Vault) Black-Backdrop Blur Guard in " + pkg);
            } else if (PKG_AOD.equals(pkg)) {
                new LivingFlowAodHook(config, bootstrap, bugGuard, telemetry)
                        .install(lpparam.classLoader);
                XposedBridge.log("CoreSurfaceEngine: initialized Non-LTPO AOD Unlock (native Doze timing) in com.miui.aod");
            } else {
                // Settings & any additional user-scoped UI app: universal SpringPhysicsCurve,
                // Toast window blur guard (protects Toasts under Advanced Textures v4), & self-unhooking bootstrap
                blurGuard.installWindowToastGuard(lpparam.classLoader);
                folmeHook.install(lpparam.classLoader);
                bootstrap.install();
                XposedBridge.log("CoreSurfaceEngine: initialized Universal UI SpringPhysicsCurve + ToastGuard in " + pkg);
            }
        } catch (Throwable t) {
            XposedBridge.log("CoreSurfaceEngine: safe isolation catch in " + pkg + ": " + t);
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
