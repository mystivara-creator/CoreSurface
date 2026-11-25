package org.mystivara.coresurface.engine;

import android.content.Context;
import android.os.Looper;
import android.view.MotionEvent;
import android.view.View;

import java.util.concurrent.ConcurrentHashMap;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * CoreSurface Luminous & Native Flagship Hook for com.android.systemui.
 *
 * Zero-lag architecture:
 * - NO View.setVisibility hook (zero overhead across SystemUI).
 * - NO custom panel translation/scale hijacking (never fights HyperOS Folme gestures).
 * - Unlocks Xiaomi's native flagship DeviceLevel/animation gates via DeviceLevelUnlockHook.
 * - Renders Zero-FBO Luminous Optical Glass overlays (max 24 deduped top-level tiles/sliders).
 * - Runs SurgicalBlurGuardHook to strip broken HyperOS 3 Toast window blur.
 */
public final class LivingFlowSystemUIHook {
    private static final int ROLE_NONE = 0;
    private static final int ROLE_EXCLUDED = 1;
    private static final int ROLE_LUMINOUS_TILE = 2;
    private static final int ROLE_LUMINOUS_PILL = 4;

    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final LuminousOverlayEngine luminousEngine;
    private final SurgicalBlurGuardHook blurGuard;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final TelemetryReporter telemetry;

    private final ConcurrentHashMap<Class<?>, Integer> classRoleCache = new ConcurrentHashMap<>();
    private volatile boolean contextBootstrapped = false;

    public LivingFlowSystemUIHook(EngineConfig config, ThermalLodController lodController,
                                  LuminousOverlayEngine luminousEngine, SurgicalBlurGuardHook blurGuard,
                                  DeviceLevelUnlockHook deviceLevelHook, TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.luminousEngine = luminousEngine;
        this.blurGuard = blurGuard;
        this.deviceLevelHook = deviceLevelHook;
        this.telemetry = telemetry;
    }

    public void install(ClassLoader cl) {
        blurGuard.installWindowToastGuard(cl);
        deviceLevelHook.install(cl);

        try {
            XposedBridge.hookAllMethods(View.class, "onAttachedToWindow", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!isMainThread() || !(param.thisObject instanceof View)) {
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

        // Non-intrusive touch specular ripple ONLY on decorated Luminous tiles (never alters scale/click)
        try {
            XposedHelpers.findAndHookMethod(View.class, "dispatchTouchEvent", MotionEvent.class, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (!isMainThread() || !(param.thisObject instanceof View)
                            || param.args == null || param.args.length < 1) {
                        return;
                    }
                    View v = (View) param.thisObject;
                    if (!luminousEngine.isDecorated(v)) {
                        return;
                    }
                    if (!(param.args[0] instanceof MotionEvent)) {
                        return;
                    }
                    MotionEvent ev = (MotionEvent) param.args[0];
                    int action = ev.getActionMasked();
                    if (action == MotionEvent.ACTION_DOWN) {
                        luminousEngine.onTileTouchDownOrMove(v, ev.getX(), ev.getY(), 1.0f);
                    } else if (action == MotionEvent.ACTION_MOVE) {
                        luminousEngine.onTileTouchDownOrMove(v, ev.getX(), ev.getY(), 0.8f);
                    } else if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                        luminousEngine.onTileTouchUp(v);
                    }
                }
            });
            telemetry.recordHookBound("TouchSpecular");
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
        config.addListener(() -> {
            telemetry.setLastConfig(config.getRawConfig());
            luminousEngine.refreshAll();
        });
    }

    private int classifyClassRole(Class<?> clazz) {
        Integer cached = classRoleCache.get(clazz);
        if (cached != null) {
            return cached;
        }
        String cls = clazz.getName().toLowerCase();
        int role = ROLE_NONE;
        if (cls.contains("toast") || cls.contains("keyboard") || cls.contains("navigationbar")
                || cls.contains("statusbar") || cls.startsWith("android.widget.")
                || cls.startsWith("androidx.")) {
            role = ROLE_EXCLUDED;
        } else if (isLuminousTileClass(cls)) {
            role = isPillClass(cls) ? ROLE_LUMINOUS_PILL : ROLE_LUMINOUS_TILE;
        }
        classRoleCache.put(clazz, role);
        return role;
    }

    private void classifyAndEnhanceView(View view) {
        int role = classifyClassRole(view.getClass());
        if (role == ROLE_EXCLUDED) {
            return;
        }

        if (role == ROLE_NONE && view.getId() != View.NO_ID) {
            String idName = safeIdName(view);
            if (!idName.isEmpty() && isLuminousTileId(idName)) {
                role = isPillClass(idName) ? ROLE_LUMINOUS_PILL : ROLE_LUMINOUS_TILE;
            }
        }

        if (role == ROLE_LUMINOUS_TILE || role == ROLE_LUMINOUS_PILL) {
            float radiusDp = (role == ROLE_LUMINOUS_PILL) ? 26.0f : 20.0f;
            luminousEngine.decorateView(view, radiusDp);
        }
    }

    private static boolean isLuminousTileClass(String cls) {
        return cls.contains("qstileview")
                || cls.contains("qsitemview")
                || cls.contains("controlcentertile")
                || cls.contains("bigtile")
                || cls.contains("expandtile")
                || cls.contains("volumeslider")
                || cls.contains("brightnessslider")
                || cls.contains("mediacontrolpanel")
                || cls.contains("mediaplayerview");
    }

    private static boolean isLuminousTileId(String idName) {
        return idName.equals("qs_tile")
                || idName.contains("control_center_tile")
                || idName.contains("brightness_slider")
                || idName.contains("volume_slider")
                || idName.contains("media_control");
    }

    private static boolean isPillClass(String token) {
        return token.contains("slider") || token.contains("pill") || token.contains("media");
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

    private static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }
}
