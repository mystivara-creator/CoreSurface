package org.mystivara.coresurface.engine;

import android.os.Looper;
import android.view.View;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * CoreSurface Launcher Physics Choreography Engine (com.miui.home).
 *
 * Drives the two highest-visibility Launcher animations natively with distinct
 * iOS Fluid / ColorOS Quantum / HyperOS 4 Crisp physics:
 *
 * 1. App Open / App Close / Swipe-Up-to-Home (`RectFSpringAnim`):
 *    - Reflectively caches spatial spring fields once per class (zero per-frame reflection).
 *    - Configures X/Y/Width/Scale SpringForce damping & stiffness = (2*pi/T)^2 and scales
 *      finger-release velocity handoff while leaving Alpha & CornerRadius springs untouched
 *      (preventing icon flicker or clip artifacts).
 * 2. Interruptible Folder Open/Close Choreography (`CoreSurfaceChoreographer`):
 *    - Drives a clean, zero-conflict `translationY` depth settle via our own CoreSpringSolver
 *      on Choreographer VSync when a Folder opens, and immediately retargets/resets to 0 on close.
 *    - Never fights Xiaomi's native Folder scaleX/scaleY or Folder blur backdrop.
 */
public final class LauncherChoreographyHook {
    private static final String CIRCUIT_RECTF = "LauncherRectF";
    private static final String CIRCUIT_FOLDER = "LauncherFolder";

    private static final String[] RECTF_CLASSES = new String[] {
            "com.miui.home.recents.util.RectFSpringAnim",
            "com.miui.home.recents.util.RectFSpringAnimBase"
    };

    private static final String[] FOLDER_CLASSES = new String[] {
            "com.miui.home.launcher.Folder",
            "com.miui.home.launcher.FolderCling",
            "com.miui.home.launcher.folder.FolderSheet"
    };

    private static final class CachedRectFFields {
        final Field[] posSpringFields;
        final Field[] scaleSpringFields;

        CachedRectFFields(Field[] pos, Field[] scale) {
            this.posSpringFields = pos;
            this.scaleSpringFields = scale;
        }
    }

    private final FolmePhysicsHook specHub;
    private final CoreSurfaceChoreographer choreographer;
    private final DeviceBugGuard bugGuard;
    private final TelemetryReporter telemetry;
    private final ConcurrentHashMap<Class<?>, CachedRectFFields> fieldCache = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Class<?>, Method> springGetterCache = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Class<?>, Method> dampSetterCache = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Class<?>, Method> stiffSetterCache = new ConcurrentHashMap<>();

    public LauncherChoreographyHook(FolmePhysicsHook specHub, CoreSurfaceChoreographer choreographer,
                                    DeviceBugGuard bugGuard, TelemetryReporter telemetry) {
        this.specHub = specHub;
        this.choreographer = choreographer;
        this.bugGuard = bugGuard;
        this.telemetry = telemetry;
    }

    public int install(ClassLoader cl) {
        if (cl == null) {
            return 0;
        }
        int hooked = 0;
        hooked += installRectFSpringHooks(cl);
        hooked += installFolderChoreographyHooks(cl);
        if (hooked > 0) {
            telemetry.addFolmeHooksBound(hooked);
            telemetry.recordHookBound("LauncherChoreography");
        }
        return hooked;
    }

    private int installRectFSpringHooks(ClassLoader cl) {
        int hooked = 0;
        for (String clsName : RECTF_CLASSES) {
            Class<?> clazz = safeFindClass(clsName, cl);
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
                if (Modifier.isAbstract(m.getModifiers()) || Modifier.isNative(m.getModifiers())) {
                    continue;
                }
                String name = m.getName();
                Class<?>[] params = m.getParameterTypes();
                if ("start".equals(name) || "startInGestureThread".equals(name)
                        || "updateEndRectF".equals(name) || "startDirectly".equals(name)) {
                    if (hookRectFStart(m)) {
                        hooked++;
                    }
                } else if ("setStartVelocity".equals(name) && params.length == 2
                        && params[0] == float.class && params[1] == float.class) {
                    if (hookRectFVelocity(m)) {
                        hooked++;
                    }
                }
            }
        }
        return hooked;
    }

    private boolean hookRectFStart(Method method) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped(CIRCUIT_RECTF) || bugGuard.isAnimationDisabledByUser()) {
                        return;
                    }
                    try {
                        MotionProfileSpec spec = specHub.getActiveSpec();
                        if (spec == null || param.thisObject == null) {
                            return;
                        }
                        if (tuneRectFSpringAnim(param.thisObject, spec)) {
                            telemetry.incSpringsTuned();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault(CIRCUIT_RECTF);
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private boolean hookRectFVelocity(Method method) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped(CIRCUIT_RECTF) || bugGuard.isAnimationDisabledByUser()) {
                        return;
                    }
                    try {
                        MotionProfileSpec spec = specHub.getActiveSpec();
                        if (spec == null || param.args == null || param.args.length < 2) {
                            return;
                        }
                        float vx = (Float) param.args[0];
                        float vy = (Float) param.args[1];
                        param.args[0] = vx * spec.appVelocityScale;
                        param.args[1] = vy * spec.appVelocityScale;
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault(CIRCUIT_RECTF);
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private boolean tuneRectFSpringAnim(Object rectAnim, MotionProfileSpec spec) {
        CachedRectFFields cached = getOrScanRectFFields(rectAnim.getClass());
        boolean tuned = false;
        float posStiff = MotionProfileSpec.responseToStiffness(spec.appPosResponseSec);
        float scaleStiff = MotionProfileSpec.responseToStiffness(spec.appScaleResponseSec);

        for (Field f : cached.posSpringFields) {
            if (applyToSpringObject(rectAnim, f, spec.appPosDamping, posStiff)) {
                tuned = true;
            }
        }
        for (Field f : cached.scaleSpringFields) {
            if (applyToSpringObject(rectAnim, f, spec.appScaleDamping, scaleStiff)) {
                tuned = true;
            }
        }
        return tuned;
    }

    private CachedRectFFields getOrScanRectFFields(Class<?> clazz) {
        CachedRectFFields existing = fieldCache.get(clazz);
        if (existing != null) {
            return existing;
        }
        ArrayList<Field> pos = new ArrayList<>();
        ArrayList<Field> scale = new ArrayList<>();
        Class<?> cur = clazz;
        while (cur != null && cur != Object.class) {
            try {
                for (Field f : cur.getDeclaredFields()) {
                    if (Modifier.isStatic(f.getModifiers())) {
                        continue;
                    }
                    String typeName = f.getType().getName().toLowerCase(Locale.ROOT);
                    if (!typeName.contains("spring")) {
                        continue;
                    }
                    String fname = f.getName().toLowerCase(Locale.ROOT);
                    // Explicitly skip alpha & corner-radius springs to prevent flash/clip glitches
                    if (fname.contains("alpha") || fname.contains("radius") || fname.contains("blur")) {
                        continue;
                    }
                    f.setAccessible(true);
                    if (fname.contains("width") || fname.contains("ratio") || fname.contains("scale")) {
                        scale.add(f);
                    } else {
                        pos.add(f);
                    }
                }
            } catch (Throwable ignored) {
            }
            cur = cur.getSuperclass();
        }
        CachedRectFFields result = new CachedRectFFields(
                pos.toArray(new Field[0]),
                scale.toArray(new Field[0]));
        fieldCache.put(clazz, result);
        return result;
    }

    private boolean applyToSpringObject(Object owner, Field f, float damping, float stiffness) {
        try {
            Object obj = f.get(owner);
            if (obj == null) {
                return false;
            }
            Object springForce = resolveSpringForce(obj);
            if (springForce == null) {
                return false;
            }
            Class<?> sfClass = springForce.getClass();
            Method mDamp = getCachedFloatMethod(sfClass, "setDampingRatio", dampSetterCache);
            Method mStiff = getCachedFloatMethod(sfClass, "setStiffness", stiffSetterCache);
            if (mDamp != null && mStiff != null) {
                mDamp.invoke(springForce, damping);
                mStiff.invoke(springForce, stiffness);
                return true;
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private Object resolveSpringForce(Object springHolder) {
        Class<?> cls = springHolder.getClass();
        String name = cls.getName().toLowerCase(Locale.ROOT);
        if (name.contains("springforce")) {
            return springHolder;
        }
        Method getter = springGetterCache.get(cls);
        if (getter == null) {
            try {
                getter = cls.getMethod("getSpring");
                springGetterCache.put(cls, getter);
            } catch (Throwable ignored) {
                return null;
            }
        }
        try {
            return getter.invoke(springHolder);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static Method getCachedFloatMethod(Class<?> cls, String name,
                                               ConcurrentHashMap<Class<?>, Method> cache) {
        Method m = cache.get(cls);
        if (m != null) {
            return m;
        }
        try {
            m = cls.getMethod(name, float.class);
            cache.put(cls, m);
            return m;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private int installFolderChoreographyHooks(ClassLoader cl) {
        int hooked = 0;
        for (String clsName : FOLDER_CLASSES) {
            Class<?> clazz = safeFindClass(clsName, cl);
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
                if (Modifier.isAbstract(m.getModifiers()) || Modifier.isNative(m.getModifiers())) {
                    continue;
                }
                String name = m.getName();
                if ("onOpen".equals(name) || "animateOpen".equals(name) || "open".equals(name)) {
                    if (hookFolderLifecycle(m, true)) {
                        hooked++;
                    }
                } else if ("onClose".equals(name) || "close".equals(name)) {
                    if (hookFolderLifecycle(m, false)) {
                        hooked++;
                    }
                }
            }
        }
        return hooked;
    }

    private boolean hookFolderLifecycle(Method method, final boolean isOpen) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped(CIRCUIT_FOLDER) || bugGuard.isAnimationDisabledByUser()) {
                        return;
                    }
                    if (Looper.myLooper() != Looper.getMainLooper() || !(param.thisObject instanceof View)) {
                        return;
                    }
                    try {
                        View v = (View) param.thisObject;
                        if (!isOpen) {
                            choreographer.cancelAndReset(v, CoreSurfaceChoreographer.PROP_TRANSLATION_Y);
                            return;
                        }
                        MotionProfileSpec spec = specHub.getActiveSpec();
                        if (spec == null || !v.isAttachedToWindow()) {
                            return;
                        }
                        float density = v.getResources() != null
                                ? v.getResources().getDisplayMetrics().density : 2.75f;
                        float liftPx = spec.surfaceLiftDp * density;
                        float initialVel = -liftPx * spec.surfaceImpulseVel;
                        choreographer.springTo(
                                v,
                                CoreSurfaceChoreographer.PROP_TRANSLATION_Y,
                                liftPx,
                                0.0f,
                                initialVel,
                                spec.surfaceDamping,
                                spec.surfaceResponseSec);
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault(CIRCUIT_FOLDER);
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static Class<?> safeFindClass(String className, ClassLoader cl) {
        try {
            return XposedHelpers.findClassIfExists(className, cl);
        } catch (Throwable ignored) {
            return null;
        }
    }
}
