package org.mystivara.coresurface.engine;

import android.content.Context;
import android.view.View;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;

/**
 * CoreSurface LivingFlow AOD Hook for com.miui.aod.
 * Adds smooth VSync-locked luminous fade + scale entrance on AOD views without
 * forcing HyperOS 3's unstable support_aod_fullscreen / mFullAodHideEase path.
 */
public final class LivingFlowAodHook {
    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final TelemetryReporter telemetry;
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
                    if (!(param.thisObject instanceof View)) {
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

    private void animateAodViewIfMatched(final View view) {
        if (!config.isAodFlow()) {
            return;
        }
        String cls = view.getClass().getName().toLowerCase();
        if (!cls.contains("aod") && !cls.contains("clock") && !cls.contains("doze")) {
            return;
        }
        try {
            view.setAlpha(0.0f);
            view.setScaleX(0.95f);
            view.setScaleY(0.95f);
            SpringPhysics spring = new SpringPhysics(0.0f, 220.0f, 0.88f, 0.002f, p -> {
                float clamped = Math.max(0.0f, Math.min(1.05f, p));
                float scale = 0.95f + 0.05f * clamped;
                view.setScaleX(scale);
                view.setScaleY(scale);
                view.setAlpha(Math.min(1.0f, clamped));
            }, () -> {
                view.setScaleX(1.0f);
                view.setScaleY(1.0f);
                view.setAlpha(1.0f);
            });
            spring.animateTo(1.0f);
            telemetry.incFlowAnimations();
        } catch (Throwable ignored) {
        }
    }
}
