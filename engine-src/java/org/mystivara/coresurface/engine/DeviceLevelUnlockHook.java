package org.mystivara.coresurface.engine;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Locale;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * Native HyperOS / MIUI Flagship DeviceLevel, Computility V1/V2 & Control Center Gate Unlocker.
 *
 * Cleanly unlocks Xiaomi's NATIVE flagship animation and blur code paths already
 * compiled inside com.android.systemui, com.miui.home, and com.miui.aod with
 * strict Never-Downgrade protection and DeviceBugGuard fault circuit-breakers:
 *   - DeviceUtils / DeviceLevel (0=LOW, 1=MID, 2=HIGH) -> min 2
 *   - ComputilityUtils V1 (cpulevel/gpulevel 1..6)     -> min 6
 *   - ComputilityUtils V2 (level 1..4)                 -> min 4
 */
public final class DeviceLevelUnlockHook {
    private static final int LEVEL_HIGH = 2;
    private static final int COMPUTILITY_V1_FLAGSHIP = 6;
    private static final int COMPUTILITY_V2_FLAGSHIP = 4;

    private static final String[] TARGET_CLASSES = new String[] {
            "miuix.device.DeviceUtils",
            "miui.util.DeviceLevel",
            "com.miui.utils.DeviceLevel",
            "miui.util.ComputilityUtils",
            "com.miui.utils.ComputilityUtils",
            "com.miui.systemui.util.ComputilityUtils",
            "com.android.systemui.controlcenter.utils.ControlCenterUtils",
            "com.miui.home.launcher.common.DeviceLevelUtils",
            "com.miui.home.launcher.DeviceConfig",
            "com.miui.home.launcher.common.CpuLevelUtils",
            "com.miui.home.launcher.common.GpuLevelUtils",
            "com.miui.utils.configs.MiuiConfigs",
            "com.miui.systemui.util.MiuiAnimationUtils",
            "com.android.systemui.statusbar.notification.utils.NotificationUtil"
    };

    private final EngineConfig config;
    private final DeviceBugGuard bugGuard;
    private final TelemetryReporter telemetry;

    public DeviceLevelUnlockHook(EngineConfig config, DeviceBugGuard bugGuard, TelemetryReporter telemetry) {
        this.config = config;
        this.bugGuard = bugGuard;
        this.telemetry = telemetry;
    }

    public int install(ClassLoader cl) {
        if (cl == null) {
            return 0;
        }
        int totalHooked = 0;

        for (String className : TARGET_CLASSES) {
            Class<?> clazz = safeFindClass(className, cl);
            if (clazz == null) {
                continue;
            }
            int count = hookClassGates(clazz, className.toLowerCase(Locale.ROOT).contains("computility"));
            totalHooked += count;
        }

        if (totalHooked > 0) {
            telemetry.addNativeGatesHooked(totalHooked);
            telemetry.recordHookBound("NativeFlagshipTier");
        }
        return totalHooked;
    }

    private Class<?> safeFindClass(String className, ClassLoader cl) {
        try {
            return XposedHelpers.findClassIfExists(className, cl);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private int hookClassGates(Class<?> clazz, boolean isComputilityClass) {
        int hooked = 0;
        Method[] methods;
        try {
            methods = clazz.getDeclaredMethods();
        } catch (Throwable ignored) {
            return 0;
        }

        for (Method m : methods) {
            if (Modifier.isAbstract(m.getModifiers()) || Modifier.isNative(m.getModifiers())) {
                continue;
            }
            String name = m.getName();
            Class<?> ret = m.getReturnType();

            if (ret == boolean.class) {
                if (isDisableLowTierMethod(name)) {
                    if (hookReturnConstant(m, Boolean.FALSE)) {
                        hooked++;
                    }
                } else if (isEnableHighTierMethod(name)) {
                    if (hookReturnConstant(m, Boolean.TRUE)) {
                        hooked++;
                    }
                }
            } else if (ret == int.class) {
                int targetLevel = resolveMinIntLevel(name, isComputilityClass);
                if (targetLevel > 0 && hookMinDeviceTier(m, targetLevel)) {
                    hooked++;
                }
            }
        }
        return hooked;
    }

    private static int resolveMinIntLevel(String name, boolean isComputilityClass) {
        String lower = name.toLowerCase(Locale.ROOT);
        if (isComputilityClass) {
            if (lower.contains("v2") || "getcomputilitylevel".equals(lower)) {
                return COMPUTILITY_V2_FLAGSHIP;
            }
            if (lower.contains("cpulevel") || lower.contains("gpulevel")) {
                return COMPUTILITY_V1_FLAGSHIP;
            }
            if (lower.contains("devicelevel")) {
                return COMPUTILITY_V2_FLAGSHIP;
            }
            return 0;
        }
        if ("getDeviceLevel".equals(name)
                || "getCpuLevel".equals(name)
                || "getGpuLevel".equals(name)
                || "getQualcommCpuLevel".equals(name)
                || "getMtkCpuLevel".equals(name)) {
            return LEVEL_HIGH;
        }
        return 0;
    }

    private boolean hookReturnConstant(Method method, final Object constantValue) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("NativeTierBool")) {
                        return;
                    }
                    try {
                        if (config.isNativeTierEnabled()) {
                            param.setResult(constantValue);
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("NativeTierBool");
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    /**
     * Never-Downgrade int tier gate: upgrades levels below minLevel
     * while preserving any higher factory tier (>= minLevel) untouched.
     */
    private boolean hookMinDeviceTier(Method method, final int minLevel) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("NativeTierInt")) {
                        return;
                    }
                    try {
                        if (!config.isNativeTierEnabled()) {
                            return;
                        }
                        Object res = param.getResult();
                        if (res instanceof Integer && ((Integer) res) < minLevel) {
                            param.setResult(minLevel);
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("NativeTierInt");
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static boolean isDisableLowTierMethod(String name) {
        return "isLowLevelOrLiteDevice".equals(name)
                || "isUseSimpleAnim".equals(name)
                || "isLowEndDevice".equals(name)
                || "isLiteDevice".equals(name)
                || "isMiuiLiteV2".equals(name)
                || "isMiuiLiteRom".equals(name)
                || "isLiteV1StockPlus".equals(name)
                || "isMiddleLevelDevice".equals(name)
                || "isLowMemoryDevices".equals(name)
                || "isForceShadeLowEndAnim".equals(name);
    }

    private static boolean isEnableHighTierMethod(String name) {
        return "isHighLevelDevice".equals(name)
                || "isHighEndDevice".equals(name)
                || "isSupportCompleteAnimation".equals(name)
                || "isSupportHighLevelAnim".equals(name)
                || "isSupportHighEndAnim".equals(name)
                || "isSupportAppAnimation".equals(name)
                || "isSupportRecentsAndFsGesture".equals(name)
                || "isBlurSupported".equals(name)
                || "isSupportSmoothAnimation".equals(name)
                || "isSupportSpringAnim".equals(name)
                || "isSupportControlCenterAnim".equals(name);
    }
}
