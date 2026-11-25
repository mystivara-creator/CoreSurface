package org.mystivara.coresurface.engine;

import android.animation.TimeInterpolator;
import android.animation.ValueAnimator;
import android.content.Context;
import android.hardware.display.DisplayManager;
import android.os.Handler;
import android.os.Looper;
import android.view.Display;
import android.view.ViewPropertyAnimator;
import android.view.animation.AccelerateDecelerateInterpolator;
import android.view.animation.DecelerateInterpolator;
import android.view.animation.PathInterpolator;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * Universal Physics-Formula Motion Engine (Folme + AnimConfig + SpringForce + ValueAnimator + ViewPropertyAnimator).
 *
 * Applies the analytical Damped Harmonic Oscillator equation (SpringPhysicsCurve)
 * across ALL UI interfaces in scoped processes (SystemUI, MiuiHome, MiuiAod, Settings,
 * and any user-enabled app) with genuinely perceptible profile signatures:
 *
 * 1. Xiaomi Folme Springs (`miuix.animation.utils.EaseManager.getStyle` & `AnimConfig.setEase`)
 * 2. Xiaomi Folme Interpolators (`miuix.animation.utils.EaseManager.getInterpolator`)
 * 3. Miui & Jetpack `SpringForce` (`setDampingRatio` & `setStiffness` via k = (2*pi/T)^2)
 * 4. Standard Android `ValueAnimator.setInterpolator` & `ViewPropertyAnimator.setInterpolator`
 *    (with finite UI transition duration scaling so iOS/ColorOS 17 Silk visibly glides
 *    and HyperOS 4 visibly whips, while strictly sparing LinearInterpolator, exit ease-in,
 *    progress spinners, and infinite animations).
 */
public final class FolmePhysicsHook {
    private static final int DEFAULT_SPRING_STYLE = -2;
    private static final int INTERP_SKIP = 0;
    private static final int INTERP_UPGRADE = 1;

    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final DeviceBugGuard bugGuard;
    private final TelemetryReporter telemetry;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ConcurrentHashMap<Class<?>, Integer> interpClassCache = new ConcurrentHashMap<>();

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
                if (hz >= 45.0f && hz <= 240.0f) {
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

        int uiHooks = 0;
        if (hookUniversalValueAnimator()) {
            uiHooks++;
        }
        if (hookUniversalViewPropertyAnimator()) {
            uiHooks++;
        }
        if (uiHooks > 0) {
            hooks += uiHooks;
            telemetry.addFolmeHooksBound(uiHooks);
            telemetry.recordHookBound("UiCurvePhysics");
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
            } else if ("getInterpolator".equals(name) && params.length == 2
                    && params[0] == int.class && params[1] == float[].class
                    && TimeInterpolator.class.isAssignableFrom(m.getReturnType())) {
                if (hookEaseGetInterpolator(m, springStyle)) {
                    hooked++;
                }
            }
        }
        return hooked;
    }

    /**
     * Hooks `miuix.animation.base.AnimConfig.setEase(int style, float... factors)` used
     * directly by HyperOS Launcher, Control Center, and SystemUI Folme transitions.
     */
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
                        if (damping < 0.45f || damping > 1.15f || response < 0.10f || response > 0.90f) {
                            return;
                        }
                        float[] copy = factors.clone();
                        applyPhysicsDampingResponse(copy, damping, response, profile, getCurveForProfile(profile));
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
                        if (damping < 0.45f || damping > 1.15f || response < 0.10f || response > 0.90f) {
                            return;
                        }
                        float[] tmp = new float[2];
                        applyPhysicsDampingResponse(tmp, damping, response, profile, getCurveForProfile(profile));
                        double[] copy = factors.clone();
                        copy[0] = tmp[0];
                        copy[1] = tmp[1];
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

    private boolean hookEaseGetInterpolator(Method method, final int springStyle) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("EaseInterp")) {
                        return;
                    }
                    try {
                        String profile = config.getMotionProfile();
                        if (EngineConfig.MOTION_OFF.equals(profile) || bugGuard.isAnimationDisabledByUser()) {
                            return;
                        }
                        if (param.args == null || param.args.length < 1 || !(param.args[0] instanceof Integer)) {
                            return;
                        }
                        int style = (Integer) param.args[0];
                        // Skip linear (style == 0 / 1) and custom spring style (already handled)
                        if (style == 0 || style == 1 || style == springStyle) {
                            return;
                        }
                        Object res = param.getResult();
                        if (res instanceof TimeInterpolator && isUpgradeableInterpolator((TimeInterpolator) res)) {
                            param.setResult(getCurveForProfile(profile));
                            telemetry.incCurvesApplied();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("EaseInterp");
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
                        if (d < 0.65f || d > 1.05f) {
                            return;
                        }
                        SpringPhysicsCurve curve = getCurveForProfile(profile);
                        // Drive damping cleanly toward the chosen physical signature (80% profile / 20% stock)
                        param.args[0] = clamp(d * 0.20f + curve.getDampingRatio() * 0.80f, 0.76f, 0.95f);
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
                        if (s < 140.0f || s > 1800.0f) {
                            return;
                        }
                        SpringPhysicsCurve curve = getCurveForProfile(profile);
                        // Weighted geometric blend strongly favoring analytical k = (2*pi/T)^2
                        double targetK = Math.pow(s, 0.25) * Math.pow(curve.getStiffnessK(), 0.75);
                        param.args[0] = clamp((float) targetK, 145.0f, 1450.0f);
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

    /**
     * Universal UI Interface Curve Hook on ValueAnimator.setInterpolator.
     * Upgrades finite UI transitions (dialogs, panels, sheets, cards, subpages) to our
     * analytical SpringPhysicsCurve AND applies subtle profile-authentic duration scaling
     * (1.24x silky glide for iOS/ColorOS 17; 0.90x crisp whip for HyperOS 4) while strictly
     * sparing LinearInterpolator, exit ease-in, progress spinners, and infinite animations.
     */
    private boolean hookUniversalValueAnimator() {
        try {
            Method mSetInterp = ValueAnimator.class.getDeclaredMethod("setInterpolator", TimeInterpolator.class);
            XposedBridge.hookMethod(mSetInterp, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("ValueAnimInterp")) {
                        return;
                    }
                    try {
                        String profile = config.getMotionProfile();
                        if (EngineConfig.MOTION_OFF.equals(profile) || bugGuard.isAnimationDisabledByUser()) {
                            return;
                        }
                        if (!(param.thisObject instanceof ValueAnimator)
                                || param.args == null || param.args.length < 1) {
                            return;
                        }
                        Object raw = param.args[0];
                        if (!(raw instanceof TimeInterpolator) || (raw instanceof SpringPhysicsCurve)) {
                            return;
                        }
                        ValueAnimator va = (ValueAnimator) param.thisObject;
                        if (va.getRepeatCount() == ValueAnimator.INFINITE || va.getRepeatCount() > 0) {
                            return;
                        }
                        long dur = va.getDuration();
                        if (dur > 0L && (dur < 110L || dur > 900L)) {
                            return;
                        }
                        if (isUpgradeableInterpolator((TimeInterpolator) raw)) {
                            SpringPhysicsCurve curve = getCurveForProfile(profile);
                            param.args[0] = curve;
                            if (dur >= 120L && dur <= 550L) {
                                long scaled = Math.round(dur * curve.getDurationScale());
                                va.setDuration(Math.max(120L, Math.min(680L, scaled)));
                            }
                            telemetry.incCurvesApplied();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("ValueAnimInterp");
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    /**
     * Universal ViewPropertyAnimator.setInterpolator hook catching `view.animate().setInterpolator(...)`
     * across SystemUI Control Center, Notifications, Launcher, and Settings.
     */
    private boolean hookUniversalViewPropertyAnimator() {
        try {
            Method mVpa = ViewPropertyAnimator.class.getDeclaredMethod("setInterpolator", TimeInterpolator.class);
            XposedBridge.hookMethod(mVpa, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("VpaInterp")) {
                        return;
                    }
                    try {
                        String profile = config.getMotionProfile();
                        if (EngineConfig.MOTION_OFF.equals(profile) || bugGuard.isAnimationDisabledByUser()) {
                            return;
                        }
                        if (!(param.thisObject instanceof ViewPropertyAnimator)
                                || param.args == null || param.args.length < 1) {
                            return;
                        }
                        Object raw = param.args[0];
                        if (!(raw instanceof TimeInterpolator) || (raw instanceof SpringPhysicsCurve)) {
                            return;
                        }
                        if (isUpgradeableInterpolator((TimeInterpolator) raw)) {
                            SpringPhysicsCurve curve = getCurveForProfile(profile);
                            param.args[0] = curve;
                            ViewPropertyAnimator vpa = (ViewPropertyAnimator) param.thisObject;
                            long dur = vpa.getDuration();
                            if (dur >= 120L && dur <= 550L) {
                                long scaled = Math.round(dur * curve.getDurationScale());
                                vpa.setDuration(Math.max(120L, Math.min(680L, scaled)));
                            }
                            telemetry.incCurvesApplied();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("VpaInterp");
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private boolean isUpgradeableInterpolator(TimeInterpolator interp) {
        // PathInterpolator instances share one Class<?>, so inspect their curve shape directly
        // to upgrade ease-out/fast-out-slow-in transitions while sparing exit (ease-in), linear,
        // and custom non-monotonic/overshoot paths.
        if (interp instanceof PathInterpolator) {
            return isEaseOutPathCurve(interp);
        }
        Class<?> clazz = interp.getClass();
        Integer cached = interpClassCache.get(clazz);
        if (cached != null) {
            return cached == INTERP_UPGRADE;
        }
        int decision = INTERP_SKIP;
        if (interp instanceof DecelerateInterpolator
                || interp instanceof AccelerateDecelerateInterpolator) {
            decision = INTERP_UPGRADE;
        } else {
            String name = clazz.getName().toLowerCase(Locale.ROOT);
            if (!name.contains("linear") && !name.contains("bounce") && !name.contains("cycle")
                    && !name.contains("overshoot") && !name.contains("anticipate")
                    && !name.contains("easein")
                    && (name.contains("fastoutslowin")
                    || name.contains("easeout")
                    || name.contains("decelerate")
                    || name.contains("cubicease")
                    || name.contains("quartease")
                    || name.contains("quintease")
                    || name.contains("sineease")
                    || name.contains("miuix.view.animation"))) {
                decision = INTERP_UPGRADE;
            }
        }
        interpClassCache.put(clazz, decision);
        return decision == INTERP_UPGRADE;
    }

    private static boolean isEaseOutPathCurve(TimeInterpolator interp) {
        try {
            float y25 = interp.getInterpolation(0.25f);
            float y50 = interp.getInterpolation(0.50f);
            float y75 = interp.getInterpolation(0.75f);
            if (y25 < 0.0f || y75 > 1.0f || !(y25 < y50 && y50 < y75)) {
                return false;
            }
            if (Math.abs(y25 - 0.25f) < 0.02f && Math.abs(y50 - 0.50f) < 0.02f && Math.abs(y75 - 0.75f) < 0.02f) {
                return false;
            }
            return y50 >= 0.45f;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private void applyPhysicsDampingResponse(float[] out, float stockDamp, float stockResp,
                                             String profile, SpringPhysicsCurve curve) {
        float targetDamp = curve.getDampingRatio();
        float targetResp = curve.getResponseSec();
        float hzFactor = clamp((currentRefreshHz - 60.0f) / 60.0f, 0.0f, 1.0f);

        if (EngineConfig.MOTION_SILK.equals(profile)) {
            // iOS 18 / ColorOS 17 Silk: unmistakable buoyant damping (0.78..0.84) + silky 1.32x-1.45x glide
            float outDamp = clamp(stockDamp * 0.20f + targetDamp * 0.80f, 0.76f, 0.86f);
            float scale = 1.28f + 0.16f * hzFactor;
            float outResp = clamp(Math.max(stockResp * scale, targetResp * 0.88f), 0.28f, 0.66f);
            out[0] = outDamp;
            out[1] = outResp;
        } else {
            // HyperOS 4 Flagship: crisp, agile, zero-sludge flagship spring
            float outDamp = clamp(stockDamp * 0.25f + targetDamp * 0.75f, 0.86f, 0.94f);
            float scale = 0.92f + 0.08f * hzFactor;
            float outResp = clamp(stockResp * scale, 0.20f, 0.46f);
            out[0] = outDamp;
            out[1] = outResp;
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
