package org.mystivara.coresurface.engine;

import android.animation.ValueAnimator;
import android.view.animation.AlphaAnimation;
import android.view.animation.Animation;
import android.view.animation.AnimationSet;
import android.view.animation.Interpolator;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.List;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * CoreSurface WMShell SurfaceControl Window Transition Physics Engine (com.android.systemui).
 *
 * Runs 100% inside SystemUI's WMShell (ZERO system_server hooks -> zero bootloop risk) to
 * drive real Android 14/15/16 App-to-App, Activity Open/Close, and Task window transitions
 * using our exact analytical CoreSpringSolver ODE physics:
 *
 * - Dynamically binds to DefaultTransitionHandler / DefaultSurfaceAnimator / MiuiDefaultTransitionHandler
 *   by parameter type (safe across AOSP 14/15/16 and HyperOS 2/3/4 signatures).
 * - Leaves startTransaction, finishTransaction, BLASTSyncEngine, and TransitionFinishCallback
 *   100% atomic and untouched (zero risk of transition hangs or black frames).
 * - Leaves pure AlphaAnimation and short (<80ms) fades native (zero opacity glitches).
 * - Replaces spatial window transition curves with our exact closed-form CoreSpringSolver
 *   physics timeline synchronized to each profile's analytical settling duration.
 */
public final class ShellTransitionPhysicsEngine {
    private static final String CIRCUIT_KEY = "ShellTransitionPhysics";

    private static final String[] WMSHELL_HANDLER_CLASSES = new String[] {
            "com.android.wm.shell.transition.DefaultTransitionHandler",
            "com.android.wm.shell.transition.DefaultSurfaceAnimator",
            "com.android.wm.shell.transition.MiuiDefaultTransitionHandler",
            "com.android.wm.shell.transition.TransitionAnimationHelper"
    };

    private final FolmePhysicsHook specHub;
    private final DeviceBugGuard bugGuard;
    private final TelemetryReporter telemetry;
    private final ThreadLocal<Long> pendingSettleMs = new ThreadLocal<>();

    public ShellTransitionPhysicsEngine(FolmePhysicsHook specHub, DeviceBugGuard bugGuard,
                                        TelemetryReporter telemetry) {
        this.specHub = specHub;
        this.bugGuard = bugGuard;
        this.telemetry = telemetry;
    }

    public int install(ClassLoader cl) {
        if (cl == null) {
            return 0;
        }
        int hooked = 0;
        for (String clsName : WMSHELL_HANDLER_CLASSES) {
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
                if ("buildSurfaceAnimation".equals(name) || "startSurfaceAnimation".equals(name)) {
                    if (hookBuildSurfaceAnimation(m)) {
                        hooked++;
                    }
                } else if ("loadAnimation".equals(name) && Animation.class.isAssignableFrom(m.getReturnType())) {
                    if (hookLoadAnimation(m)) {
                        hooked++;
                    }
                }
            }
        }
        if (hooked > 0) {
            telemetry.addFolmeHooksBound(hooked);
            telemetry.recordHookBound("ShellTransitionPhysics");
        }
        return hooked;
    }

    private boolean hookBuildSurfaceAnimation(Method method) {
        Class<?>[] params = method.getParameterTypes();
        int animIdx = -1;
        int listIdx = -1;
        for (int i = 0; i < params.length; i++) {
            if (animIdx < 0 && Animation.class.isAssignableFrom(params[i])) {
                animIdx = i;
            } else if (listIdx < 0 && List.class.isAssignableFrom(params[i])) {
                listIdx = i;
            }
        }
        if (animIdx < 0) {
            return false;
        }
        final int fAnimIdx = animIdx;
        final int fListIdx = listIdx;
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    pendingSettleMs.remove();
                    if (bugGuard.isHookTripped(CIRCUIT_KEY) || bugGuard.isAnimationDisabledByUser()) {
                        return;
                    }
                    try {
                        MotionProfileSpec spec = specHub.getActiveSpec();
                        if (spec == null || param.args == null || param.args.length <= fAnimIdx) {
                            return;
                        }
                        Object rawAnim = param.args[fAnimIdx];
                        if (!(rawAnim instanceof Animation)) {
                            return;
                        }
                        if (applyPhysicsToShellAnimation((Animation) rawAnim, spec)) {
                            pendingSettleMs.set(spec.shellSettleMs);
                            telemetry.incCurvesApplied();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault(CIRCUIT_KEY);
                    }
                }

                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    Long extra = pendingSettleMs.get();
                    pendingSettleMs.remove();
                    if (fListIdx < 0 || extra == null || bugGuard.isHookTripped(CIRCUIT_KEY)) {
                        return;
                    }
                    try {
                        long targetMs = extra;
                        if (param.args == null || param.args.length <= fListIdx) {
                            return;
                        }
                        Object rawList = param.args[fListIdx];
                        if (!(rawList instanceof List)) {
                            return;
                        }
                        List<?> list = (List<?>) rawList;
                        if (list.isEmpty()) {
                            return;
                        }
                        Object last = list.get(list.size() - 1);
                        if (last instanceof ValueAnimator) {
                            ValueAnimator va = (ValueAnimator) last;
                            long cur = va.getDuration();
                            if (cur >= 80L && cur <= 900L && cur != targetMs) {
                                va.setDuration(targetMs);
                            }
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault(CIRCUIT_KEY);
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private boolean hookLoadAnimation(Method method) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped(CIRCUIT_KEY) || bugGuard.isAnimationDisabledByUser()) {
                        return;
                    }
                    try {
                        MotionProfileSpec spec = specHub.getActiveSpec();
                        if (spec == null) {
                            return;
                        }
                        Object res = param.getResult();
                        if (res instanceof Animation) {
                            if (applyPhysicsToShellAnimation((Animation) res, spec)) {
                                telemetry.incCurvesApplied();
                            }
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault(CIRCUIT_KEY);
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    /**
     * Applies CoreSpringSolver physics to spatial window transition animations while keeping
     * pure AlphaAnimation and short (<80ms) fades 100% untouched.
     */
    private static boolean applyPhysicsToShellAnimation(Animation anim, MotionProfileSpec spec) {
        if (anim == null || anim instanceof AlphaAnimation) {
            return false;
        }
        long dur = anim.getDuration();
        if (dur > 0L && (dur < 80L || dur > 950L)) {
            return false;
        }

        if (anim instanceof AnimationSet) {
            AnimationSet set = (AnimationSet) anim;
            List<Animation> children = set.getAnimations();
            if (children == null || children.isEmpty()) {
                return false;
            }
            boolean appliedSpatial = false;
            CoreSpringInterpolator spatialInterp = new CoreSpringInterpolator(spec, spec.shellAllowOvershoot);
            CoreSpringInterpolator monotonicInterp = new CoreSpringInterpolator(spec, false);
            for (int i = 0; i < children.size(); i++) {
                Animation child = children.get(i);
                if (child == null) {
                    continue;
                }
                if (child instanceof AlphaAnimation) {
                    // Never overshoot opacity; keep short alpha fades untouched
                    if (child.getDuration() >= 120L) {
                        child.setInterpolator(monotonicInterp);
                    }
                } else {
                    child.setInterpolator(spatialInterp);
                    if (child.getDuration() >= 80L && child.getDuration() <= 900L) {
                        child.setDuration(spec.shellSettleMs);
                    }
                    appliedSpatial = true;
                }
            }
            if (appliedSpatial && dur >= 80L && dur <= 900L) {
                set.setDuration(spec.shellSettleMs);
            }
            return appliedSpatial;
        }

        anim.setInterpolator(new CoreSpringInterpolator(spec, spec.shellAllowOvershoot));
        if (dur >= 80L && dur <= 900L) {
            anim.setDuration(spec.shellSettleMs);
        }
        return true;
    }

    /**
     * Exact closed-form CoreSpringSolver interpolator evaluated over the transition's
     * physical settle duration with C1 endpoint closure so t=0 -> 0.0 and t=1 -> 1.0.
     */
    private static final class CoreSpringInterpolator implements Interpolator {
        private final double damping;
        private final double responseSec;
        private final double v0;
        private final double settleSec;
        private final double residual;
        private final float maxBound;

        CoreSpringInterpolator(MotionProfileSpec spec, boolean allowOvershoot) {
            this.damping = allowOvershoot ? spec.shellDamping : Math.max(spec.shellDamping, 0.98);
            this.responseSec = spec.shellResponseSec;
            this.v0 = spec.shellInitialVelocity;
            this.settleSec = Math.max(0.20, spec.shellSettleMs / 1000.0);
            this.residual = 1.0 - CoreSpringSolver.evaluateUnit(this.damping, this.responseSec, this.settleSec, this.v0);
            this.maxBound = allowOvershoot ? spec.shellMaxOvershoot : 1.0f;
        }

        @Override
        public float getInterpolation(float input) {
            if (input <= 0.0f) {
                return 0.0f;
            }
            if (input >= 1.0f) {
                return 1.0f;
            }
            double t = input * settleSec;
            double raw = CoreSpringSolver.evaluateUnit(damping, responseSec, t, v0);
            // Smooth cubic C1 closure guarantees exact arrival at 1.0 with zero snap
            double s = input;
            double val = raw + residual * (s * s * s);
            if (val < 0.0) {
                return 0.0f;
            }
            if (val > maxBound) {
                return maxBound;
            }
            return (float) val;
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
