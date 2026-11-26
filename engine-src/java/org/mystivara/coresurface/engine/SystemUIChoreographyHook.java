package org.mystivara.coresurface.engine;

import android.os.Looper;
import android.view.View;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * CoreSurface Control Center & Notification Shade Choreography Hook (com.android.systemui).
 *
 * Uses our own CoreSurfaceChoreographer (CoreSpringSolver on VSync) to add an authentic,
 * mid-flight interruptible tactile spring settle when HyperOS Control Center or Quick Settings
 * tiles reveal, cleanly cancelling on collapse with 0% idle CPU/GPU cost and zero blur interference.
 */
public final class SystemUIChoreographyHook {
    private static final String CIRCUIT_KEY = "SystemUIChoreo";

    private static final String[] PANEL_VIEW_CLASSES = new String[] {
            "com.android.systemui.controlcenter.phone.ControlCenterPanelView",
            "com.android.systemui.controlcenter.panel.MiuiControlCenterPanelView",
            "com.android.systemui.controlcenter.phone.ControlPanelWindowView",
            "com.android.systemui.controlcenter.view.ControlCenterView",
            "com.android.systemui.controlcenter.phone.widget.ControlCenterContainer",
            "com.android.systemui.qs.MiuiQSContainerImpl"
    };

    private final FolmePhysicsHook specHub;
    private final CoreSurfaceChoreographer choreographer;
    private final DeviceBugGuard bugGuard;
    private final TelemetryReporter telemetry;

    public SystemUIChoreographyHook(FolmePhysicsHook specHub, CoreSurfaceChoreographer choreographer,
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
        for (String clsName : PANEL_VIEW_CLASSES) {
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
                if ("onVisibilityChanged".equals(name) && params.length == 2
                        && View.class.isAssignableFrom(params[0]) && params[1] == int.class) {
                    if (hookPanelVisibility(m)) {
                        hooked++;
                    }
                } else if (("showPanel".equals(name) || "openPanel".equals(name) || "expand".equals(name))
                        && params.length <= 1) {
                    if (hookPanelAction(m, true)) {
                        hooked++;
                    }
                } else if (("hidePanel".equals(name) || "collapse".equals(name)) && params.length <= 1) {
                    if (hookPanelAction(m, false)) {
                        hooked++;
                    }
                }
            }
        }
        if (hooked > 0) {
            telemetry.addFolmeHooksBound(hooked);
            telemetry.recordHookBound("SystemUIChoreography");
        }
        return hooked;
    }

    private boolean hookPanelVisibility(Method method) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped(CIRCUIT_KEY) || bugGuard.isAnimationDisabledByUser()) {
                        return;
                    }
                    if (Looper.myLooper() != Looper.getMainLooper()
                            || !(param.thisObject instanceof View)
                            || param.args == null || param.args.length < 2) {
                        return;
                    }
                    try {
                        View v = (View) param.thisObject;
                        int vis = (Integer) param.args[1];
                        if (vis == View.VISIBLE) {
                            triggerPanelSpring(v);
                        } else {
                            choreographer.cancelAndReset(v, CoreSurfaceChoreographer.PROP_TRANSLATION_Y);
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

    private boolean hookPanelAction(Method method, final boolean open) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped(CIRCUIT_KEY) || bugGuard.isAnimationDisabledByUser()) {
                        return;
                    }
                    if (Looper.myLooper() != Looper.getMainLooper() || !(param.thisObject instanceof View)) {
                        return;
                    }
                    try {
                        View v = (View) param.thisObject;
                        if (open) {
                            triggerPanelSpring(v);
                        } else {
                            choreographer.cancelAndReset(v, CoreSurfaceChoreographer.PROP_TRANSLATION_Y);
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

    private void triggerPanelSpring(View v) {
        MotionProfileSpec spec = specHub.getActiveSpec();
        if (spec == null || !v.isAttachedToWindow()) {
            return;
        }
        float density = v.getResources() != null
                ? v.getResources().getDisplayMetrics().density : 2.75f;
        // Subtle downward spring glide from top edge into natural rest (0f)
        float startY = -(spec.surfaceLiftDp * 1.15f) * density;
        float initialVel = Math.abs(startY) * spec.surfaceImpulseVel;
        choreographer.springTo(
                v,
                CoreSurfaceChoreographer.PROP_TRANSLATION_Y,
                startY,
                0.0f,
                initialVel,
                spec.surfaceDamping,
                spec.surfaceResponseSec);
    }

    private static Class<?> safeFindClass(String className, ClassLoader cl) {
        try {
            return XposedHelpers.findClassIfExists(className, cl);
        } catch (Throwable ignored) {
            return null;
        }
    }
}
