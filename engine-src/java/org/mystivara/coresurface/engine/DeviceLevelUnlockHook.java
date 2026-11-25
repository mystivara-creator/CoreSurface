package org.mystivara.coresurface.engine;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * Native HyperOS / MIUI Flagship DeviceLevel & Animation Gate Unlocker.
 *
 * Instead of fighting HyperOS's own Folme animator by mutating View.scaleX/translationX
 * externally (which caused Launcher & Control Center jitter), this hook cleanly unlocks
 * Xiaomi's NATIVE flagship animation and blur code paths already compiled inside
 * com.android.systemui, com.miui.home, and com.miui.aod.
 *
 * Zero-gimmick guarantee: dynamically probes classes via reflection and reports the
 * exact count of native HyperOS gate methods actually bound on this ROM.
 */
public final class DeviceLevelUnlockHook {
    // Standard HyperOS / MIUIX high-end device tier constant (0=LOW, 1=MIDDLE, 2=HIGH)
    private static final int LEVEL_HIGH = 2;

    private static final String[] TARGET_CLASSES = new String[] {
            "miuix.device.DeviceUtils",
            "miui.util.DeviceLevel",
            "com.miui.utils.DeviceLevel",
            "com.miui.home.launcher.common.DeviceLevelUtils",
            "com.miui.home.launcher.DeviceConfig",
            "com.miui.home.launcher.common.CpuLevelUtils",
            "com.miui.home.launcher.common.GpuLevelUtils",
            "com.miui.utils.configs.MiuiConfigs",
            "com.miui.systemui.util.MiuiAnimationUtils",
            "com.android.systemui.statusbar.notification.utils.NotificationUtil"
    };

    private final EngineConfig config;
    private final TelemetryReporter telemetry;

    public DeviceLevelUnlockHook(EngineConfig config, TelemetryReporter telemetry) {
        this.config = config;
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
            int count = hookClassGates(clazz);
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

    private int hookClassGates(Class<?> clazz) {
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
                if (isDeviceTierIntMethod(name)) {
                    if (hookReturnConstant(m, LEVEL_HIGH)) {
                        hooked++;
                    }
                }
            }
        }
        return hooked;
    }

    private boolean hookReturnConstant(Method method, final Object constantValue) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (config.isLivingFlow()) {
                        param.setResult(constantValue);
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
                || "isLowMemoryDevices".equals(name);
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
                || "isSupportSmoothAnimation".equals(name);
    }

    private static boolean isDeviceTierIntMethod(String name) {
        return "getDeviceLevel".equals(name)
                || "getCpuLevel".equals(name)
                || "getGpuLevel".equals(name)
                || "getQualcommCpuLevel".equals(name)
                || "getMtkCpuLevel".equals(name);
    }
}
