package org.mystivara.coresurface.engine;

import android.content.Context;
import android.os.Looper;
import android.view.View;

import java.util.WeakHashMap;
import java.util.concurrent.ConcurrentHashMap;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;

/**
 * CoreSurface LivingFlow AOD Hook for com.miui.aod.
 * Adds smooth VSync-locked luminous fade + scale entrance on AOD views without
 * forcing HyperOS 3's unstable support_aod_fullscreen / mFullAodHideEase path.
 */
public final class LivingFlowAodHook {
    private static final int AOD_NO = 0;
    private static final int AOD_YES = 1;

    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final TelemetryReporter telemetry;
    private final ConcurrentHashMap<Class<?>, Integer> aodClassCache = new ConcurrentHashMap<>();
    private final WeakHashMap<View, SpringPhysics> activeSprings = new WeakHashMap<>();
    private volatile boolean contextBootstrapped = false;

    public LivingFlowAodHook(EngineConfig config, ThermalLodController lodController, TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.telemetry = telemetry;
    }

    public void install() {
        try {
            XposedBridge.hookAllMethods(View.class, "onAttachedToWindow", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!isMainThread() || !(param.thisObject instanceof View)) {
                        return;
                    }
                    View view = (View) param.thisObject;
                    bootstrapIfNeeded(view.getContext());
                    animateAodViewIfMatched(view);
                }
            });
            telemetry.recordHookBound("AodLivingFlow");
        } catch (Throwable ignored) {
        }
    }

    private void bootstrapIfNeeded(Context ctx) {
        if (contextBootstrapped || ctx == null) {
            return;
        }
        contextBootstrapped = true;
        config.attachContext(ctx);
        telemetry.attachContext(ctx);
        lodController.attachContext(ctx);
        telemetry.setLastConfig(config.getRawConfig());
        config.addListener(() -> telemetry.setLastConfig(config.getRawConfig()));
    }

    private boolean isAodTargetClass(Class<?> clazz) {
        Integer cached = aodClassCache.get(clazz);
        if (cached != null) {
            return cached == AOD_YES;
        }
        String cls = clazz.getName().toLowerCase();
        boolean match = (cls.contains("aod") || cls.contains("clock") || cls.contains("doze"))
                && !cls.startsWith("android.widget.");
        aodClassCache.put(clazz, match ? AOD_YES : AOD_NO);
        return match;
    }

    private void animateAodViewIfMatched(final View view) {
        if (!config.isAodFlow() || !isAodTargetClass(view.getClass())) {
            return;
        }
        try {
            SpringPhysics prev = activeSprings.remove(view);
            if (prev != null) {
                prev.cancel();
            }
            view.setAlpha(0.15f);
            view.setScaleX(0.95f);
            view.setScaleY(0.95f);
            SpringPhysics spring = new SpringPhysics(0.0f, 220.0f, 0.88f, 0.002f, p -> {
                float clamped = Math.max(0.0f, Math.min(1.04f, p));
                float scale = 0.95f + 0.05f * clamped;
                view.setScaleX(scale);
                view.setScaleY(scale);
                view.setAlpha(Math.min(1.0f, 0.15f + 0.85f * clamped));
            }, () -> {
                activeSprings.remove(view);
                view.setScaleX(1.0f);
                view.setScaleY(1.0f);
                view.setAlpha(1.0f);
            });
            activeSprings.put(view, spring);
            spring.animateTo(1.0f);
            telemetry.incFlowAnimations();
        } catch (Throwable ignored) {
        }
    }

    private static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }
}
