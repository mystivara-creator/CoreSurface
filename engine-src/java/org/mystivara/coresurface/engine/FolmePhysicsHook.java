package org.mystivara.coresurface.engine;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * Native HyperOS Folme & Jetpack SpringForce Physics Tuner.
 *
 * Preserves 100% original HyperOS visual design with ZERO custom overlays, ZERO FBOs,
 * and ZERO competing animators. Instead, refines Xiaomi's own native 120 Hz Folme
 * (`miuix.animation.utils.EaseManager`, `miuix.animation.physics.SpringForce`) and
 * Android `SpringForce` spring parameters into flagship motion curves:
 *
 * - `hyperos4`: Crisp, airy HyperOS 4 flagship spring feel (softens rigid mid-range
 *               damping & extends settle response by +12%).
 * - `silk`:     Silky iOS / ColorOS 17 continuous momentum spring feel (fluid damping
 *               0.82-0.90 & response +24%).
 * - `off`:      100% stock ROM curves (instant live switch, zero reboot).
 *
 * Thermal-Adaptive Safety: Automatically tightens response toward snappy 1.0x when
 * ThermalLodController reports SEVERE thermal status.
 */
public final class FolmePhysicsHook {
    private static final int DEFAULT_SPRING_STYLE = -2;

    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final TelemetryReporter telemetry;

    public FolmePhysicsHook(EngineConfig config, ThermalLodController lodController, TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.telemetry = telemetry;
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
                    int style = (Integer) param.args[0];
                    if (style != springStyle) {
                        return;
                    }
                    float[] factors = (float[]) param.args[1];
                    if (factors == null || factors.length < 2) {
                        return;
                    }
                    float damping = factors[0];
                    float response = factors[1];
                    // Only refine normal UI motion springs; leave bounce/instant snaps untouched
                    if (damping < 0.60f || damping > 1.05f || response < 0.14f || response > 0.70f) {
                        return;
                    }
                    float[] tuned = tuneDampingResponse(damping, response, profile);
                    float[] copy = factors.clone();
                    copy[0] = tuned[0];
                    copy[1] = tuned[1];
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
                    int style = (Integer) param.args[0];
                    if (style != springStyle) {
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
                    float[] tuned = tuneDampingResponse(damping, response, profile);
                    double[] copy = factors.clone();
                    copy[0] = tuned[0];
                    copy[1] = tuned[1];
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
                    float thermalWeight = getThermalScale();
                    float target = EngineConfig.MOTION_SILK.equals(profile)
                            ? clamp(d * (1.0f - 0.08f * thermalWeight), 0.82f, 0.90f)
                            : clamp(d * (1.0f - 0.05f * thermalWeight), 0.85f, 0.93f);
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
                    float thermalWeight = getThermalScale();
                    float mult = EngineConfig.MOTION_SILK.equals(profile)
                            ? (1.0f - 0.24f * thermalWeight)
                            : (1.0f - 0.14f * thermalWeight);
                    param.args[0] = clamp(s * mult, 150.0f, 1400.0f);
                }
            });
            hooked++;
        } catch (Throwable ignored) {
        }

        return hooked;
    }

    private float[] tuneDampingResponse(float damping, float response, String profile) {
        float w = getThermalScale();
        float outDamp = damping;
        float outResp = response;

        if (EngineConfig.MOTION_SILK.equals(profile)) {
            // iOS / ColorOS 17 silky fluid momentum
            if (damping > 0.84f) {
                outDamp = clamp(damping - (damping - 0.84f) * (0.55f * w), 0.82f, 0.91f);
            }
            outResp = clamp(response * (1.0f + 0.24f * w), 0.20f, 0.64f);
        } else {
            // HyperOS 4 crisp flagship spring
            if (damping > 0.88f) {
                outDamp = clamp(damping - (damping - 0.88f) * (0.45f * w), 0.85f, 0.93f);
            }
            outResp = clamp(response * (1.0f + 0.13f * w), 0.18f, 0.56f);
        }
        return new float[] { outDamp, outResp };
    }

    private float getThermalScale() {
        float lod = lodController.getEffectiveLod();
        if (lod <= ThermalLodController.LOD_ECO + 0.05f) {
            return 0.35f;
        }
        if (lod <= ThermalLodController.LOD_BALANCED + 0.05f) {
            return 0.70f;
        }
        return 1.0f;
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
