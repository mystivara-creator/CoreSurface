package org.mystivara.coresurface.engine;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Locale;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * CoreSurface Native Flagship, Motion & Non-LTPO AOD Unlock Hook for com.miui.aod.
 *
 * Safely removes Xiaomi's software 10-second AOD cap ("For 10 seconds after tapping") on
 * non-LTPO AMOLED panels so "Always" and "Scheduled" appear in Display items:
 *   1. Hooks miui.util.FeatureParser.getBoolean("is_only_support_keycode_goto", ...) -> false
 *      and AOD capability keys -> true.
 *   2. Hooks MiuiAod utility & settings capability gates (including keycode-goto restriction
 *      and 10s-cap methods) without ever touching HyperOS 3's unstable mFullAodHideEase field.
 */
public final class LivingFlowAodHook {
    private static final String[] AOD_UTIL_CLASSES = new String[] {
            "com.miui.aod.utils.CommonUtils",
            "com.miui.aod.utils.MiuiAodUtils",
            "com.miui.aod.utils.DeviceUtils",
            "com.miui.aod.utils.AodConfig",
            "com.miui.aod.AODApplication",
            "com.miui.aod.settings.AodShowModePreference",
            "com.miui.aod.settings.AodShowModeSettingsActivity",
            "com.miui.aod.settings.AodShowModeFragment",
            "com.miui.aod.settings.AodStyleCategoriesActivity"
    };

    private final EngineConfig config;
    private final ProcessBootstrap bootstrap;
    private final DeviceBugGuard bugGuard;
    private final FolmePhysicsHook folmeHook;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final TelemetryReporter telemetry;

    public LivingFlowAodHook(EngineConfig config, ProcessBootstrap bootstrap,
                             DeviceBugGuard bugGuard, FolmePhysicsHook folmeHook,
                             DeviceLevelUnlockHook deviceLevelHook, TelemetryReporter telemetry) {
        this.config = config;
        this.bootstrap = bootstrap;
        this.bugGuard = bugGuard;
        this.folmeHook = folmeHook;
        this.deviceLevelHook = deviceLevelHook;
        this.telemetry = telemetry;
    }

    public void install(ClassLoader cl) {
        int nativeGates = deviceLevelHook.install(cl);
        folmeHook.install(cl);

        int aodGates = installFeatureParserAodHook(cl);
        aodGates += installNonLtpoAodGates(cl);
        if (aodGates > 0) {
            telemetry.addAodGatesHooked(aodGates);
            telemetry.recordHookBound("AodNonLtpoUnlock");
        }
        if (nativeGates > 0 || aodGates > 0) {
            telemetry.recordHookBound("AodFlagshipTier");
        }

        bootstrap.install();
    }

    /**
     * Hooks miui.util.FeatureParser.getBoolean(String, boolean) inside com.miui.aod so
     * is_only_support_keycode_goto ALWAYS evaluates to false (unlocking "Always" & "Scheduled")
     * even if the ROM caches device_features XML.
     */
    private int installFeatureParserAodHook(ClassLoader cl) {
        if (cl == null) {
            return 0;
        }
        try {
            Class<?> fpClass = XposedHelpers.findClassIfExists("miui.util.FeatureParser", cl);
            if (fpClass == null) {
                return 0;
            }
            Method getBool = fpClass.getDeclaredMethod("getBoolean", String.class, boolean.class);
            XposedBridge.hookMethod(getBool, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("AodFeatureParser")) {
                        return;
                    }
                    try {
                        if (!config.isAodUnlockEnabled() || param.args == null || param.args.length < 1
                                || !(param.args[0] instanceof String)) {
                            return;
                        }
                        String key = (String) param.args[0];
                        if ("is_only_support_keycode_goto".equals(key)) {
                            param.setResult(Boolean.FALSE);
                        } else if ("support_aod".equals(key)
                                || "support_aod_aon".equals(key)
                                || "aod_support_keycode_goto_dismiss".equals(key)
                                || "is_video_screen".equals(key)) {
                            param.setResult(Boolean.TRUE);
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("AodFeatureParser");
                    }
                }
            });
            return 1;
        } catch (Throwable ignored) {
            return 0;
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
                String lower = m.getName().toLowerCase(Locale.ROOT);
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
                    if (bugGuard.isHookTripped("AodNonLtpoGate")) {
                        return;
                    }
                    try {
                        if (config.isAodUnlockEnabled()) {
                            param.setResult(desired);
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("AodNonLtpoGate");
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
                || lower.contains("isonly10s")
                || lower.contains("onlysupportkeycodegoto")
                || lower.contains("supportkeycodegotoonly")
                || lower.contains("isonlykeycodegoto")
                || lower.contains("onlykeycodegoto");
    }
}
