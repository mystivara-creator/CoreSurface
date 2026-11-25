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
 * Lightweight Native Folme & SpringForce Physics Refinement Hook.
 *
 * Strictly zero-gimmick, ultra-low overhead:
 * - NEVER hijacks standard Android ValueAnimator, ViewPropertyAnimator, or XML Animation.
 * - NEVER stretches durations or injects synthetic overshoot onto standard UI widgets.
 * - In `off` (Stock Flagship) mode: 100% pass-through so unlocked Xiaomi Native Flagship
 *   Folme runs completely untouched.
 * - In `hyperos4` (Flagship Crisp) or `silk` (Smooth Flow) mode: applies a gentle 70/30
 *   blend to true physics springs (`EaseManager.getStyle`, `AnimConfig.setEase`, `SpringForce`)
 *   so every component keeps its natural Xiaomi rhythm while feeling consistently smooth.
 */
public final class FolmePhysicsHook {
    private static final int DEFAULT_SPRING_STYLE = -2;

    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final DeviceBugGuard bugGuard;
    private final TelemetryReporter telemetry;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private volatile boolean displayAttached = false;
    private volatile float currentRefreshHz = 60.0f;
    private volatile float cachedThermalScale = 1.0f;
    private volatile SpringPhysicsCurve activeCurve = SpringPhysicsCurve.forProfile(
            EngineConfig.MOTION_HYPEROS4, 60.0f, 1.0f);
    private volatile String activeCurveProfile = EngineConfig.MOTION_HYPEROS4;

    public FolmePhysicsHook(EngineConfig config, ThermalLodController lodController,
                            DeviceBugGuard bugGuard, TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.bugGuard = bugGuard;
        this.telemetry = telemetry;
        this.lodController.addListener(this::rebuildCurveState);
        this.config.addListener(this::rebuildCurveState);
    }

    public void attachContext(Context context) {
        if (context == null || displayAttached) {
            return;
        }
        displayAttached = true;
        rebuildCurveState();
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
                if (hz >= 45.0f && hz <= 240.0f && Math.abs(hz - currentRefreshHz) >= 0.5f) {
                    currentRefreshHz = hz;
                    telemetry.setDisplayHz(Math.round(hz));
                    rebuildCurveState();
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private void rebuildCurveState() {
        float lod = lodController.getEffectiveLod();
        if (lod <= ThermalLodController.LOD_ECO + 0.05f) {
            cachedThermalScale = 0.35f;
        } else if (lod <= ThermalLodController.LOD_BALANCED + 0.05f) {
            cachedThermalScale = 0.70f;
        } else {
            cachedThermalScale = 1.0f;
        }
        String profile = config.getMotionProfile();
        activeCurveProfile = profile;
        if (!EngineConfig.MOTION_OFF.equals(profile)) {
            activeCurve = SpringPhysicsCurve.forProfile(profile, currentRefreshHz, cachedThermalScale);
        }
    }

    private SpringPhysicsCurve getCurveForProfile(String profile) {
        if (!profile.equals(activeCurveProfile)) {
            activeCurveProfile = profile;
            activeCurve = SpringPhysicsCurve.forProfile(profile, currentRefreshHz, cachedThermalScale);
        }
        return activeCurve;
    }

    public int install(ClassLoader cl) {
        if (cl == null) {
            return 0;
        }
        int hooks = 0;
        int springStyle = resolveSpringStyleFromLoader(cl);
        hooks += hookEaseManager(cl, springStyle);
        hooks += hookAnimConfigSetEase(cl, springStyle);
        hooks += hookSpringForceClass(cl, "miuix.animation.physics.SpringForce");
        hooks += hookSpringForceClass(cl, "androidx.dynamicanimation.animation.SpringForce");

        if (hooks > 0) {
            telemetry.addFolmeHooksBound(hooks);
            telemetry.recordHookBound("FolmePhysics");
        }
        return hooks;
    }

    private int resolveSpringStyleFromLoader(ClassLoader cl) {
        Class<?> easeClass = safeFindClass("miuix.animation.utils.EaseManager", cl);
        return easeClass != null ? resolveSpringStyleConstant(easeClass) : DEFAULT_SPRING_STYLE;
    }

    private int hookEaseManager(ClassLoader cl, int springStyle) {
        Class<?> easeClass = safeFindClass("miuix.animation.utils.EaseManager", cl);
        if (easeClass == null) {
            return 0;
        }

        int hooked = 0;
        Method[] methods;
        try {
            methods = easeClass.getDeclaredMethods();
        } catch (Throwable ignored) {
            return 0;
        }

        for (Method m : methods) {
            if (Modifier.isAbstract(m.getModifiers())) {
                continue;
            }
            String name = m.getName();
            Class<?>[] params = m.getParameterTypes();

            if ("getStyle".equals(name) && params.length == 2 && params[0] == int.class) {
                if (params[1] == float[].class && hookEaseGetStyleFloat(m, springStyle, "EaseStyleFloat")) {
                    hooked++;
                } else if (params[1] == double[].class && hookEaseGetStyleDouble(m, springStyle)) {
                    hooked++;
                }
            }
        }
        return hooked;
    }

    private int hookAnimConfigSetEase(ClassLoader cl, int springStyle) {
        Class<?> animCfgClass = safeFindClass("miuix.animation.base.AnimConfig", cl);
        if (animCfgClass == null) {
            return 0;
        }
        int hooked = 0;
        try {
            Method[] methods = animCfgClass.getDeclaredMethods();
            for (Method m : methods) {
                if (Modifier.isAbstract(m.getModifiers()) || !"setEase".equals(m.getName())) {
                    continue;
                }
                Class<?>[] params = m.getParameterTypes();
                if (params.length == 2 && params[0] == int.class && params[1] == float[].class) {
                    if (hookEaseGetStyleFloat(m, springStyle, "AnimConfigEase")) {
                        hooked++;
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        return hooked;
    }

    private boolean hookEaseGetStyleFloat(Method method, final int springStyle, final String circuitKey) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped(circuitKey)) {
                        return;
                    }
                    try {
                        String profile = config.getMotionProfile();
                        if (EngineConfig.MOTION_OFF.equals(profile) || bugGuard.isAnimationDisabledByUser()) {
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
                        // Only gently refine normal UI transition springs; leave micro/extreme springs native
                        if (damping < 0.65f || damping > 1.05f || response < 0.18f || response > 0.70f) {
                            return;
                        }
                        float[] copy = factors.clone();
                        applySubtleSpringBlend(copy, damping, response, profile, getCurveForProfile(profile));
                        param.args[1] = copy;
                        telemetry.incSpringsTuned();
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault(circuitKey);
                    }
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
                    if (bugGuard.isHookTripped("EaseStyleDouble")) {
                        return;
                    }
                    try {
                        String profile = config.getMotionProfile();
                        if (EngineConfig.MOTION_OFF.equals(profile) || bugGuard.isAnimationDisabledByUser()) {
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
                        if (damping < 0.65f || damping > 1.05f || response < 0.18f || response > 0.70f) {
                            return;
                        }
                        double[] copy = factors.clone();
                        applySubtleSpringBlendDouble(copy, damping, response, profile, getCurveForProfile(profile));
                        param.args[1] = copy;
                        telemetry.incSpringsTuned();
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("EaseStyleDouble");
                    }
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
                    if (bugGuard.isHookTripped("SpringDamp")) {
                        return;
                    }
                    try {
                        String profile = config.getMotionProfile();
                        if (EngineConfig.MOTION_OFF.equals(profile) || bugGuard.isAnimationDisabledByUser()
                                || param.args == null || param.args.length < 1) {
                            return;
                        }
                        float d = (Float) param.args[0];
                        if (d < 0.70f || d > 1.05f) {
                            return;
                        }
                        SpringPhysicsCurve curve = getCurveForProfile(profile);
                        // Gentle 70% native / 30% target blend preserves natural widget character
                        param.args[0] = clamp(d * 0.70f + curve.getDampingRatio() * 0.30f, 0.80f, 0.98f);
                        telemetry.incSpringsTuned();
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("SpringDamp");
                    }
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
                    if (bugGuard.isHookTripped("SpringStiff")) {
                        return;
                    }
                    try {
                        String profile = config.getMotionProfile();
                        if (EngineConfig.MOTION_OFF.equals(profile) || bugGuard.isAnimationDisabledByUser()
                                || param.args == null || param.args.length < 1) {
                            return;
                        }
                        float s = (Float) param.args[0];
                        if (s < 150.0f || s > 1800.0f) {
                            return;
                        }
                        SpringPhysicsCurve curve = getCurveForProfile(profile);
                        double targetK = Math.pow(s, 0.75) * Math.pow(curve.getStiffnessK(), 0.25);
                        param.args[0] = clamp((float) targetK, 150.0f, 1650.0f);
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("SpringStiff");
                    }
                }
            });
            hooked++;
        } catch (Throwable ignored) {
        }

        return hooked;
    }

    private void applySubtleSpringBlend(float[] out, float stockDamp, float stockResp,
                                        String profile, SpringPhysicsCurve curve) {
        float targetDamp = curve.getDampingRatio();
        if (EngineConfig.MOTION_SILK.equals(profile)) {
            out[0] = clamp(stockDamp * 0.70f + targetDamp * 0.30f, 0.80f, 0.96f);
            out[1] = clamp(stockResp * 1.06f, 0.20f, 0.56f);
        } else {
            out[0] = clamp(stockDamp * 0.70f + targetDamp * 0.30f, 0.86f, 0.98f);
            out[1] = clamp(stockResp * 0.94f, 0.18f, 0.48f);
        }
    }

    private void applySubtleSpringBlendDouble(double[] out, float stockDamp, float stockResp,
                                              String profile, SpringPhysicsCurve curve) {
        float targetDamp = curve.getDampingRatio();
        if (EngineConfig.MOTION_SILK.equals(profile)) {
            out[0] = clamp(stockDamp * 0.70f + targetDamp * 0.30f, 0.80f, 0.96f);
            out[1] = clamp(stockResp * 1.06f, 0.20f, 0.56f);
        } else {
            out[0] = clamp(stockDamp * 0.70f + targetDamp * 0.30f, 0.86f, 0.98f);
            out[1] = clamp(stockResp * 0.94f, 0.18f, 0.48f);
        }
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
