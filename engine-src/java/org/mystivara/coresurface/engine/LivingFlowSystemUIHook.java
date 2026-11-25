package org.mystivara.coresurface.engine;

import android.content.Context;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;

import java.util.WeakHashMap;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * CoreSurface LivingFlow & Luminous Hook for com.android.systemui.
 * - Applies native AGSL Luminous Optical Glass to Control Center tiles, QS cards,
 *   Brightness/Volume sliders, Media/Island pills, and Notification rows.
 * - Adds tactile LivingFlow spring press + finger-centered specular bloom on tiles.
 * - Drives smooth VSync-locked LivingFlow spring transitions on Control Center / Shade
 *   panel reveal & left-right switching, plus AOD-to-Lockscreen luminous wake.
 */
public final class LivingFlowSystemUIHook {
    private static final int TAG_TOUCH_WIRED = 0x5C30B201;
    private static final int TAG_PANEL_SPRING = 0x5C30B202;

    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final LuminousShaderEngine shaderEngine;
    private final SurgicalBlurGuardHook blurGuard;
    private final TelemetryReporter telemetry;
    private final WeakHashMap<View, SpringPhysics> panelSprings = new WeakHashMap<>();
    private volatile boolean contextBootstrapped = false;

    public LivingFlowSystemUIHook(EngineConfig config, ThermalLodController lodController,
                                  LuminousShaderEngine shaderEngine, SurgicalBlurGuardHook blurGuard,
                                  TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.shaderEngine = shaderEngine;
        this.blurGuard = blurGuard;
        this.telemetry = telemetry;
    }

    public void install(ClassLoader cl) {
        blurGuard.installWindowToastGuard(cl);

        try {
            XposedBridge.hookAllMethods(View.class, "onAttachedToWindow", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!(param.thisObject instanceof View)) {
                        return;
                    }
                    View view = (View) param.thisObject;
                    bootstrapIfNeeded(view.getContext());
                    classifyAndEnhanceView(view);
                }
            });
            telemetry.recordHookBound("LuminousGlass");
        } catch (Throwable ignored) {
        }

        try {
            final WeakHashMap<View, Integer> prevVisMap = new WeakHashMap<>();
            XposedHelpers.findAndHookMethod(View.class, "setVisibility", int.class, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (param.thisObject instanceof View) {
                        View v = (View) param.thisObject;
                        prevVisMap.put(v, v.getVisibility());
                    }
                }

                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!(param.thisObject instanceof View)) {
                        return;
                    }
                    View view = (View) param.thisObject;
                    Integer prev = prevVisMap.remove(view);
                    int nextVis = (Integer) param.args[0];
                    if (prev != null && prev == nextVis) {
                        return;
                    }
                    if (nextVis == View.VISIBLE) {
                        handlePanelOrKeyguardVisible(view);
                    }
                }
            });
            telemetry.recordHookBound("ControlCenterFlow");
            telemetry.recordHookBound("KeyguardAodFlow");
        } catch (Throwable ignored) {
        }

        // Non-intrusive touch observation: never replaces existing OnTouchListener on sliders/tiles
        try {
            XposedHelpers.findAndHookMethod(View.class, "dispatchTouchEvent", MotionEvent.class, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (!(param.thisObject instanceof View) || param.args == null || param.args.length < 1) {
                        return;
                    }
                    View v = (View) param.thisObject;
                    if (!Boolean.TRUE.equals(v.getTag(TAG_TOUCH_WIRED))) {
                        return;
                    }
                    if (!(param.args[0] instanceof MotionEvent)) {
                        return;
                    }
                    handleTactileTouch(v, (MotionEvent) param.args[0]);
                }
            });
            telemetry.recordHookBound("TactileSpring");
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
        shaderEngine.attachSensorContext(ctx);
        telemetry.setLastConfig(config.getRawConfig());
        config.addListener(() -> {
            telemetry.setLastConfig(config.getRawConfig());
            shaderEngine.refreshAllVisibleViews();
        });
    }

    private void classifyAndEnhanceView(View view) {
        String cls = view.getClass().getName().toLowerCase();
        if (cls.contains("toast") || cls.contains("keyboard") || cls.contains("navigationbar")) {
            return;
        }

        String idName = safeIdName(view);
        if (isLuminousTileCandidate(cls, idName)) {
            float radiusDp = isPillCandidate(cls, idName) ? 28.0f : 22.0f;
            shaderEngine.decorateView(view, radiusDp);
            view.setTag(TAG_TOUCH_WIRED, Boolean.TRUE);
        }
    }

    private void handlePanelOrKeyguardVisible(View view) {
        String cls = view.getClass().getName().toLowerCase();
        String idName = safeIdName(view);

        // 1. Control Center <-> Notification Shade LivingFlow fluid switch
        if (config.isLivingFlow() && isControlCenterOrShadePanel(cls, idName)) {
            boolean fromRight = cls.contains("control") || idName.contains("control_center") || idName.contains("qs_");
            runPanelFlowSpring(view, fromRight ? 36.0f : -36.0f, 0.955f);
            shaderEngine.refreshAllVisibleViews();
            return;
        }

        // 2. AOD -> Lockscreen luminous wake settle (safe on HyperOS 3 without touching mFullAodHideEase)
        if (config.isAodFlow() && isLockscreenClockOrStatus(cls, idName)) {
            runAodToLockscreenReveal(view);
        }
    }

    private void runPanelFlowSpring(final View view, float startOffsetX, final float startScale) {
        try {
            SpringPhysics old = panelSprings.get(view);
            if (old != null) {
                old.cancel();
            }
            view.setAlpha(0.72f);
            view.setScaleX(startScale);
            view.setScaleY(startScale);
            view.setTranslationX(startOffsetX);

            final float origX = startOffsetX;
            SpringPhysics spring = new SpringPhysics(0.0f, 420.0f, 0.84f, 0.002f, progress -> {
                float p = Math.max(0.0f, Math.min(1.12f, progress));
                float scale = startScale + (1.0f - startScale) * p;
                view.setScaleX(scale);
                view.setScaleY(scale);
                view.setTranslationX(origX * (1.0f - p));
                view.setAlpha(Math.min(1.0f, 0.72f + 0.28f * p));
            }, () -> {
                view.setScaleX(1.0f);
                view.setScaleY(1.0f);
                view.setTranslationX(0.0f);
                view.setAlpha(1.0f);
            });
            panelSprings.put(view, spring);
            spring.animateTo(1.0f, 2.2f);
            telemetry.incFlowAnimations();
        } catch (Throwable ignored) {
        }
    }

    private void runAodToLockscreenReveal(final View view) {
        try {
            SpringPhysics old = panelSprings.get(view);
            if (old != null) {
                old.cancel();
            }
            view.setAlpha(0.62f);
            view.setScaleX(0.93f);
            view.setScaleY(0.93f);
            view.setTranslationY(-18.0f);

            SpringPhysics spring = new SpringPhysics(0.0f, 290.0f, 0.82f, 0.002f, progress -> {
                float p = Math.max(0.0f, Math.min(1.08f, progress));
                float scale = 0.93f + 0.07f * p;
                view.setScaleX(scale);
                view.setScaleY(scale);
                view.setTranslationY(-18.0f * (1.0f - p));
                view.setAlpha(Math.min(1.0f, 0.62f + 0.38f * p));
            }, () -> {
                view.setScaleX(1.0f);
                view.setScaleY(1.0f);
                view.setTranslationY(0.0f);
                view.setAlpha(1.0f);
            });
            panelSprings.put(view, spring);
            spring.animateTo(1.0f, 1.5f);
            telemetry.incFlowAnimations();
        } catch (Throwable ignored) {
        }
    }

    private void handleTactileTouch(final View v, MotionEvent event) {
        try {
            int action = event.getActionMasked();
            final float ex = event.getX();
            final float ey = event.getY();
            if (action == MotionEvent.ACTION_DOWN) {
                if (config.isLivingFlow()) {
                    SpringPhysics old = panelSprings.get(v);
                    if (old != null) {
                        old.cancel();
                    }
                    SpringPhysics s = new SpringPhysics(v.getScaleX(), 560.0f, 0.78f, 0.002f, val -> {
                        v.setScaleX(val);
                        v.setScaleY(val);
                    }, null);
                    panelSprings.put(v, s);
                    s.animateTo(0.945f);
                }
                if (config.isLuminousGlass()) {
                    shaderEngine.pulseTouchGlow(v, ex, ey, 1.0f);
                }
            } else if (action == MotionEvent.ACTION_MOVE && config.isLuminousGlass()) {
                shaderEngine.pulseTouchGlow(v, ex, ey, 0.85f);
            } else if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                if (config.isLivingFlow()) {
                    SpringPhysics old = panelSprings.get(v);
                    if (old != null) {
                        old.cancel();
                    }
                    SpringPhysics s = new SpringPhysics(v.getScaleX(), 460.0f, 0.68f, 0.002f, val -> {
                        v.setScaleX(val);
                        v.setScaleY(val);
                    }, () -> {
                        v.setScaleX(1.0f);
                        v.setScaleY(1.0f);
                    });
                    panelSprings.put(v, s);
                    s.animateTo(1.0f, 1.4f);
                }
                if (config.isLuminousGlass()) {
                    SpringPhysics g = new SpringPhysics(0.85f, 300.0f, 0.90f, 0.01f,
                            val -> shaderEngine.pulseTouchGlow(v, ex, ey, val),
                            () -> shaderEngine.pulseTouchGlow(v, ex, ey, 0.0f));
                    g.animateTo(0.0f);
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private static boolean isLuminousTileCandidate(String cls, String idName) {
        return cls.contains("qstileview")
                || cls.contains("miuiqs")
                || cls.contains("controlcentertile")
                || cls.contains("bigtile")
                || cls.contains("volumeslider")
                || cls.contains("brightnessslider")
                || cls.contains("expandablenotificationrow")
                || cls.contains("mediacontrolpanel")
                || cls.contains("island")
                || idName.contains("qs_tile")
                || idName.contains("control_center_tile")
                || idName.contains("brightness_slider")
                || idName.contains("volume_slider")
                || idName.contains("media_control")
                || idName.contains("dynamic_island");
    }

    private static boolean isPillCandidate(String cls, String idName) {
        return cls.contains("slider") || cls.contains("island") || cls.contains("pill")
                || idName.contains("slider") || idName.contains("island");
    }

    private static boolean isControlCenterOrShadePanel(String cls, String idName) {
        return cls.contains("controlcenterpanel")
                || cls.contains("miuicontrolcenter")
                || cls.contains("notificationstackscrolllayout")
                || cls.contains("miuiqscontainer")
                || idName.equals("control_center_panel")
                || idName.equals("notification_stack_scroller")
                || idName.equals("qs_container");
    }

    private static boolean isLockscreenClockOrStatus(String cls, String idName) {
        return cls.contains("keyguardclock")
                || cls.contains("miuikeyguardclock")
                || cls.contains("keyguardstatusview")
                || idName.contains("keyguard_clock")
                || idName.contains("miui_keyguard_clock");
    }

    private static String safeIdName(View view) {
        int id = view.getId();
        if (id == View.NO_ID || view.getResources() == null) {
            return "";
        }
        try {
            String name = view.getResources().getResourceEntryName(id);
            return name != null ? name.toLowerCase() : "";
        } catch (Throwable ignored) {
            return "";
        }
    }
}
