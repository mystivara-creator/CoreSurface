package org.mystivara.coresurface.engine;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;

import java.lang.ref.WeakReference;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;

/**
 * CoreSurface LivingFlow & Surgical Recents Guard Hook for com.miui.home (HyperOS Launcher).
 * - Triggers flagship staggered radial LivingFlow spring cascade on Lockscreen -> Home unlock
 *   (ACTION_USER_PRESENT) across visible workspace icons/widgets at native 60/90/120 Hz VSync.
 * - Enhances Launcher folders with AGSL Luminous Optical Glass.
 * - Surgically fixes HyperOS 3 black Recent Apps fallback scrims.
 */
public final class LivingFlowHomeHook {
    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final LuminousShaderEngine shaderEngine;
    private final SurgicalBlurGuardHook blurGuard;
    private final TelemetryReporter telemetry;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private volatile boolean contextBootstrapped = false;
    private volatile WeakReference<ViewGroup> workspaceRef = new WeakReference<>(null);
    private long lastUnlockAnimMs = 0L;

    public LivingFlowHomeHook(EngineConfig config, ThermalLodController lodController,
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
                    inspectHomeView(view);
                }
            });

            XposedBridge.hookAllMethods(View.class, "onVisibilityChanged", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!(param.thisObject instanceof View)) {
                        return;
                    }
                    View view = (View) param.thisObject;
                    blurGuard.sanitizeRecentsViewIfNeeded(view);
                }
            });

            telemetry.recordHookBound("HomeLivingFlow");
            telemetry.recordHookBound("RecentsGuard");
        } catch (Throwable ignored) {
        }
    }

    private void bootstrapIfNeeded(Context ctx) {
        if (contextBootstrapped || ctx == null) {
            return;
        }
        contextBootstrapped = true;
        Context appCtx = ctx.getApplicationContext() != null ? ctx.getApplicationContext() : ctx;
        config.attachContext(appCtx);
        telemetry.attachContext(appCtx);
        lodController.attachContext(appCtx);
        shaderEngine.attachSensorContext(appCtx);
        telemetry.setLastConfig(config.getRawConfig());
        config.addListener(() -> {
            telemetry.setLastConfig(config.getRawConfig());
            shaderEngine.refreshAllVisibleViews();
        });

        registerUnlockReceiver(appCtx);
    }

    private void registerUnlockReceiver(Context appCtx) {
        try {
            BroadcastReceiver unlockReceiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    if (intent != null && Intent.ACTION_USER_PRESENT.equals(intent.getAction())) {
                        mainHandler.post(() -> triggerLockscreenToHomeCascade());
                    }
                }
            };
            IntentFilter filter = new IntentFilter(Intent.ACTION_USER_PRESENT);
            if (Build.VERSION.SDK_INT >= 33) {
                appCtx.registerReceiver(unlockReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
            } else {
                appCtx.registerReceiver(unlockReceiver, filter);
            }
            telemetry.recordHookBound("UnlockCascade");
        } catch (Throwable ignored) {
        }
    }

    private void inspectHomeView(View view) {
        blurGuard.sanitizeRecentsViewIfNeeded(view);

        String cls = view.getClass().getName().toLowerCase();
        if (view instanceof ViewGroup) {
            if (cls.contains("shortcutandwidgetcontainer") || cls.contains("celllayout") || cls.contains("workspace")) {
                ViewGroup vg = (ViewGroup) view;
                if (vg.getChildCount() >= 2) {
                    workspaceRef = new WeakReference<>(vg);
                }
            }
        }

        if (cls.contains("folder") && (cls.contains("content") || cls.contains("background") || cls.contains("container"))) {
            shaderEngine.decorateView(view, 28.0f);
        }
    }

    private void triggerLockscreenToHomeCascade() {
        if (!config.isLivingFlow()) {
            return;
        }
        long now = System.currentTimeMillis();
        if (now - lastUnlockAnimMs < 450L) {
            return;
        }
        lastUnlockAnimMs = now;

        ViewGroup workspace = workspaceRef.get();
        if (workspace == null || !workspace.isAttachedToWindow()) {
            return;
        }

        try {
            ViewGroup targetContainer = findBestIconContainer(workspace);
            if (targetContainer == null) {
                return;
            }
            int count = Math.min(targetContainer.getChildCount(), 32);
            if (count <= 0) {
                return;
            }

            float centerX = targetContainer.getWidth() * 0.5f;
            float centerY = targetContainer.getHeight() * 0.5f;
            float maxDist = Math.max(1.0f, (float) Math.hypot(centerX, centerY));

            for (int i = 0; i < count; i++) {
                final View child = targetContainer.getChildAt(i);
                if (child == null || child.getVisibility() != View.VISIBLE) {
                    continue;
                }
                float cx = child.getX() + child.getWidth() * 0.5f;
                float cy = child.getY() + child.getHeight() * 0.5f;
                float dx = cx - centerX;
                float dy = cy - centerY;
                float normDist = Math.min(1.0f, (float) Math.hypot(dx, dy) / maxDist);

                // Radial outward offset + subtle zoom-out that springs cleanly home
                final float startTx = dx * 0.085f;
                final float startTy = dy * 0.085f + 16.0f;
                long delayMs = (long) (normDist * 75.0f);

                child.setAlpha(0.20f);
                child.setScaleX(0.84f);
                child.setScaleY(0.84f);
                child.setTranslationX(startTx);
                child.setTranslationY(startTy);

                mainHandler.postDelayed(() -> {
                    SpringPhysics spring = new SpringPhysics(0.0f, 340.0f, 0.76f, 0.002f, progress -> {
                        float p = Math.max(0.0f, Math.min(1.12f, progress));
                        float scale = 0.84f + 0.16f * p;
                        child.setScaleX(scale);
                        child.setScaleY(scale);
                        child.setTranslationX(startTx * (1.0f - p));
                        child.setTranslationY(startTy * (1.0f - p));
                        child.setAlpha(Math.min(1.0f, 0.20f + 0.80f * p));
                    }, () -> {
                        child.setScaleX(1.0f);
                        child.setScaleY(1.0f);
                        child.setTranslationX(0.0f);
                        child.setTranslationY(0.0f);
                        child.setAlpha(1.0f);
                    });
                    spring.animateTo(1.0f, 1.8f);
                }, delayMs);
            }
            telemetry.incFlowAnimations();
        } catch (Throwable ignored) {
        }
    }

    private static ViewGroup findBestIconContainer(ViewGroup root) {
        if (root.getChildCount() >= 4) {
            View first = root.getChildAt(0);
            if (!(first instanceof ViewGroup) || first.getClass().getName().toLowerCase().contains("icon")) {
                return root;
            }
        }
        int bestCount = root.getChildCount();
        ViewGroup best = root;
        for (int i = 0; i < Math.min(root.getChildCount(), 8); i++) {
            View child = root.getChildAt(i);
            if (child instanceof ViewGroup && child.isShown()) {
                ViewGroup sub = (ViewGroup) child;
                if (sub.getChildCount() > bestCount) {
                    bestCount = sub.getChildCount();
                    best = sub;
                }
            }
        }
        return best;
    }
}
