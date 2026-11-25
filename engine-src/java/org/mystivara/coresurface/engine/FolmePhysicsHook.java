package org.mystivara.coresurface.engine;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.os.Handler;
import android.os.Looper;
import android.view.Display;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * Refresh-Rate-Aware Native HyperOS Folme & Jetpack SpringForce Physics Tuner.
 *
 * Preserves 100% original HyperOS visual design with ZERO custom overlays, ZERO FBOs,
 * and ZERO competing animators. Dynamically adapts spring damping & response to BOTH
 * 60 Hz and 90/120 Hz display modes via DisplayManager.DisplayListener (zero polling):
 *
 * - 60 Hz (16.67ms/frame): Tight, crisp damping (0.85-0.94) & controlled response (+6% to +12%)
 *   so animations stay snappy and consistent without floaty tail stutter.
 * - 90/120 Hz (8.33ms/frame): Fluid flagship settle curves (+13% HyperOS 4, +22% iOS/ColorOS Silk).
 * - Thermal-Adaptive Safety: Automatically scales curve intensity toward stock 1.0x when
 *   ThermalLodController reports MODERATE/SEVERE thermal status.
 */
public final class FolmePhysicsHook {
    private static final int DEFAULT_SPRING_STYLE = -2;

    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final TelemetryReporter telemetry;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private volatile boolean displayAttached = false;
    private volatile float currentRefreshHz = 60.0f;
    private volatile float cachedThermalScale = 1.0f;

    public FolmePhysicsHook(EngineConfig config, ThermalLodController lodController, TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.telemetry = telemetry;
        this.lodController.addListener(this::refreshThermalScale);
    }

    public void attachContext(Context context) {
        if (context == null || displayAttached) {
            return;
        }
        displayAttached = true;
        refreshThermalScale();
        try {
            Context appCtx = context.getApplicationContext() != null ? context.getApplicationContext() : context;
            DisplayManager dm = (DisplayManager) appCtx.getSystemService(Context.DISPLAY_SERVICE);
            if (dm == null) {
                return;
            }
            updateDisplayRate(dm);
            dm.registerDisplayListener(new DisplayManager.DisplayListener() {
                @Override
                public void onDisplayAdded(int displayId) {
                }

                @Override
                public void onDisplayRemoved(int displayId) {
                }

                @Override
                public void onDisplayChanged(int displayId) {
                    if (displayId == Display.DEFAULT_DISPLAY) {
                        updateDisplayRate(dm);
                    }
                }
            }, mainHandler);
        } catch (Throwable ignored) {
        }
    }

    private void updateDisplayRate(DisplayManager dm) {
        try {
            Display d = dm.getDisplay(Display.DEFAULT_DISPLAY);
            if (d != null) {
                float hz = d.getRefreshRate();
                if (hz >= 45.0f && hz <= 240.0f) {
                    currentRefreshHz = hz;
                    telemetry.setDisplayHz(Math.round(hz));
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private void refreshThermalScale() {
        float lod = lodController.getEffectiveLod();
        if (lod <= ThermalLodController.LOD_ECO + 0.05f) {
            cachedThermalScale = 0.35f;
        } else if (lod <= ThermalLodController.LOD_BALANCED + 0.05f) {
            cachedThermalScale = 0.70f;
        } else {
            cachedThermalScale = 1.0f;
        }
    }

    public int install(ClassLoader cl) {
        if (cl == null) {
            return 0;
        }
        int hooks = 0;
        hooks += hookEaseManager(cl);
        hooks += hookSpringForceClass(cl, "miuix.animation.physics.SpringForce");
        hooks += hookSpringForceClass(cl, "androidx.dynamicanimation.animation.SpringForce");

        if (hooks > 0) {
            telemetry.addFolmeHooksBound(hooks);
            telemetry.recordHookBound("FolmePhysics");
        }
        return hooks;
    }

    private int hookEaseManager(ClassLoader cl) {
        Class<?> easeClass = safeFindClass("miuix.animation.utils.EaseManager", cl);
        if (easeClass == null) {
            return 0;
        }

        final int springStyle = resolveSpringStyleConstant(easeClass);
        int hooked = 0;

        Method[] methods;
        try {
            methods = easeClass.getDeclaredMethods();
        } catch (Throwable ignored) {
            return 0;
        }

        for (Method m : methods) {
            if (Modifier.isAbstract(m.getModifiers()) || !"getStyle".equals(m.getName())) {
                continue;
            }
            Class<?>[] params = m.getParameterTypes();
            if (params.length != 2 || params[0] != int.class) {
                continue;
            }

            if (params[1] == float[].class) {
                if (hookEaseGetStyleFloat(m, springStyle)) {
                    hooked++;
                }
            } else if (params[1] == double[].class) {
                if (hookEaseGetStyleDouble(m, springStyle)) {
                    hooked++;
                }
            }
        }
        return hooked;
    }

    private boolean hookEaseGetStyleFloat(Method method, final int springStyle) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    String profile = config.getMotionProfile();
                    if (EngineConfig.MOTION_OFF.equals(profile)) {
                        return;
                    }
                    if (param.args == null || param.args.length < 2) {
                        return;
                    }
                    if (!(param.args[0] instanceof Integer) || !(param.args[1] instanceof float[])) {
                        return;
                    }
                    if (((Integer) param.args[0]) != springStyle) {
                        return;
                    }
                    float[] factors = (float[]) param.args[1];
                    if (factors == null || factors.length < 2) {
                        return;
                    }
                    float damping = factors[0];
                    float response = factors[1];
                    if (damping < 0.60f || damping > 1.05f || response < 0.14f || response > 0.70f) {
                        return;
                    }
                    float[] copy = factors.clone();
                    applyTunedCurve(copy, damping, response, profile);
                    param.args[1] = copy;
                    telemetry.incSpringsTuned();
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private boolean hookEaseGetStyleDouble(Method method, final int springStyle) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    String profile = config.getMotionProfile();
                    if (EngineConfig.MOTION_OFF.equals(profile)) {
                        return;
                    }
                    if (param.args == null || param.args.length < 2) {
                        return;
                    }
                    if (!(param.args[0] instanceof Integer) || !(param.args[1] instanceof double[])) {
                        return;
                    }
                    if (((Integer) param.args[0]) != springStyle) {
                        return;
                    }
                    double[] factors = (double[]) param.args[1];
                    if (factors == null || factors.length < 2) {
                        return;
                    }
                    float damping = (float) factors[0];
                    float response = (float) factors[1];
                    if (damping < 0.60f || damping > 1.05f || response < 0.14f || response > 0.70f) {
                        return;
                    }
                    double[] copy = factors.clone();
                    applyTunedCurveDouble(copy, damping, response, profile);
                    param.args[1] = copy;
                    telemetry.incSpringsTuned();
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private int hookSpringForceClass(ClassLoader cl, String className) {
        Class<?> sfClass = safeFindClass(className, cl);
        if (sfClass == null) {
            return 0;
        }
        int hooked = 0;

        try {
            Method mDamp = sfClass.getDeclaredMethod("setDampingRatio", float.class);
            XposedBridge.hookMethod(mDamp, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    String profile = config.getMotionProfile();
                    if (EngineConfig.MOTION_OFF.equals(profile) || param.args == null || param.args.length < 1) {
                        return;
                    }
                    float d = (Float) param.args[0];
                    if (d < 0.75f || d > 1.02f) {
                        return;
                    }
                    boolean highHz = currentRefreshHz > 75.0f;
                    float w = cachedThermalScale;
                    float target;
                    if (EngineConfig.MOTION_SILK.equals(profile)) {
                        target = highHz
                                ? clamp(d * (1.0f - 0.08f * w), 0.82f, 0.90f)
                                : clamp(d * (1.0f - 0.05f * w), 0.85f, 0.92f);
                    } else {
                        target = highHz
                                ? clamp(d * (1.0f - 0.05f * w), 0.85f, 0.93f)
                                : clamp(d * (1.0f - 0.03f * w), 0.88f, 0.94f);
                    }
                    param.args[0] = target;
                    telemetry.incSpringsTuned();
                }
            });
            hooked++;
        } catch (Throwable ignored) {
        }

        try {
            Method mStiff = sfClass.getDeclaredMethod("setStiffness", float.class);
            XposedBridge.hookMethod(mStiff, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    String profile = config.getMotionProfile();
                    if (EngineConfig.MOTION_OFF.equals(profile) || param.args == null || param.args.length < 1) {
                        return;
                    }
                    float s = (Float) param.args[0];
                    if (s < 180.0f || s > 1600.0f) {
                        return;
                    }
                    boolean highHz = currentRefreshHz > 75.0f;
                    float w = cachedThermalScale;
                    float reduction;
                    if (EngineConfig.MOTION_SILK.equals(profile)) {
                        reduction = (highHz ? 0.22f : 0.12f) * w;
                    } else {
                        reduction = (highHz ? 0.13f : 0.07f) * w;
                    }
                    param.args[0] = clamp(s * (1.0f - reduction), 160.0f, 1450.0f);
                }
            });
            hooked++;
        } catch (Throwable ignored) {
        }

        return hooked;
    }

    private void applyTunedCurve(float[] out, float damping, float response, String profile) {
        boolean highHz = currentRefreshHz > 75.0f;
        float w = cachedThermalScale;
        float outDamp = damping;
        float outResp;

        if (EngineConfig.MOTION_SILK.equals(profile)) {
            if (highHz) {
                if (damping > 0.84f) {
                    outDamp = clamp(damping - (damping - 0.84f) * (0.55f * w), 0.82f, 0.90f);
                }
                outResp = clamp(response * (1.0f + 0.22f * w), 0.20f, 0.62f);
            } else {
                // 60 Hz Silk: controlled smooth settle without sluggish tail frames
                if (damping > 0.86f) {
                    outDamp = clamp(damping - (damping - 0.86f) * (0.40f * w), 0.85f, 0.92f);
                }
                outResp = clamp(response * (1.0f + 0.12f * w), 0.19f, 0.52f);
            }
        } else {
            if (highHz) {
                if (damping > 0.88f) {
                    outDamp = clamp(damping - (damping - 0.88f) * (0.45f * w), 0.85f, 0.93f);
                }
                outResp = clamp(response * (1.0f + 0.13f * w), 0.18f, 0.54f);
            } else {
                // 60 Hz HyperOS 4: crisp, immediate response with clean frame landing
                if (damping > 0.90f) {
                    outDamp = clamp(damping - (damping - 0.90f) * (0.35f * w), 0.88f, 0.94f);
                }
                outResp = clamp(response * (1.0f + 0.06f * w), 0.17f, 0.46f);
            }
        }
        out[0] = outDamp;
        out[1] = outResp;
    }

    private void applyTunedCurveDouble(double[] out, float damping, float response, String profile) {
        float[] tmp = new float[2];
        applyTunedCurve(tmp, damping, response, profile);
        out[0] = tmp[0];
        out[1] = tmp[1];
    }

    private static int resolveSpringStyleConstant(Class<?> easeClass) {
        for (String name : new String[] { "SPRING", "SPRING_PHY" }) {
            try {
                Field f = easeClass.getField(name);
                if (f.getType() == int.class) {
                    return f.getInt(null);
                }
            } catch (Throwable ignored) {
            }
        }
        return DEFAULT_SPRING_STYLE;
    }

    private static Class<?> safeFindClass(String className, ClassLoader cl) {
        try {
            return XposedHelpers.findClassIfExists(className, cl);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static float clamp(float v, float min, float max) {
        return Math.max(min, Math.min(max, v));
    }
}
