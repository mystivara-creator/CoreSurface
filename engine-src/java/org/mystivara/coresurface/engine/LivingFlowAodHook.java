package org.mystivara.coresurface.engine;

import android.app.Application;
import android.content.Context;
import android.view.View;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * CoreSurface Native Flagship, Motion & Non-LTPO AOD Unlock Hook for com.miui.aod.
 *
 * Safely removes Xiaomi's software 10-second AOD cap on non-LTPO AMOLED panels by
 * hooking MiuiAod utility capability gates (without ever touching HyperOS 3's unstable
 * mFullAodHideEase private field).
 */
public final class LivingFlowAodHook {
    private static final String[] AOD_UTIL_CLASSES = new String[] {
            "com.miui.aod.utils.CommonUtils",
            "com.miui.aod.utils.MiuiAodUtils",
            "com.miui.aod.utils.DeviceUtils",
            "com.miui.aod.AODApplication",
            "com.miui.aod.settings.AodShowModePreference",
            "com.miui.aod.settings.AodStyleCategoriesActivity"
    };

    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final DeviceBugGuard bugGuard;
    private final FolmePhysicsHook folmeHook;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final TelemetryReporter telemetry;
    private volatile boolean contextBootstrapped = false;

    public LivingFlowAodHook(EngineConfig config, ThermalLodController lodController,
                             DeviceBugGuard bugGuard, FolmePhysicsHook folmeHook,
                             DeviceLevelUnlockHook deviceLevelHook, TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.bugGuard = bugGuard;
        this.folmeHook = folmeHook;
        this.deviceLevelHook = deviceLevelHook;
        this.telemetry = telemetry;
    }

    public void install(ClassLoader cl) {
        deviceLevelHook.install(cl);
        folmeHook.install(cl);

        int aodGates = installNonLtpoAodGates(cl);
        if (aodGates > 0) {
            telemetry.addAodGatesHooked(aodGates);
            telemetry.recordHookBound("AodNonLtpoUnlock");
        }

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

    private int installNonLtpoAodGates(ClassLoader cl) {
        if (cl == null) {
            return 0;
        }
        int hooked = 0;
        for (String clsName : AOD_UTIL_CLASSES) {
            Class<?> clazz;
            try {
                clazz = XposedHelpers.findClassIfExists(clsName, cl);
            } catch (Throwable ignored) {
                clazz = null;
            }
            if (clazz == null) {
                continue;
            }
            Method[] methods;
            try {
                methods = clazz.getDeclaredMethods();
            } catch (Throwable ignored) {
                continue;
            }
            for (Method m : methods) {
                if (Modifier.isAbstract(m.getModifiers()) || m.getReturnType() != boolean.class) {
                    continue;
                }
                if (m.getParameterTypes().length > 1) {
                    continue;
                }
                String lower = m.getName().toLowerCase();
                if (isAlwaysOnSupportMethod(lower)) {
                    if (hookBoolResult(m, true)) {
                        hooked++;
                    }
                } else if (is10sCapMethod(lower)) {
                    if (hookBoolResult(m, false)) {
                        hooked++;
                    }
                }
            }
        }
        return hooked;
    }

    private boolean hookBoolResult(Method method, final boolean desired) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (config.isAodUnlockEnabled()) {
                        param.setResult(desired);
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static boolean isAlwaysOnSupportMethod(String lower) {
        return lower.contains("supportaodalways")
                || lower.contains("alwaysshowsupport")
                || lower.contains("supportalwayson")
                || lower.contains("supportalwaysdisplay")
                || lower.contains("issupportalways");
    }

    private static boolean is10sCapMethod(String lower) {
        return lower.contains("onlysupport10s")
                || lower.contains("support10sonly")
                || lower.contains("aod10sonly")
                || lower.contains("onlytaptoshow")
                || lower.contains("support10smode")
                || lower.contains("need10slimit")
                || lower.contains("isonly10s");
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
