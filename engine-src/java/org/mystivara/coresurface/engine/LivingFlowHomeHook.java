package org.mystivara.coresurface.engine;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Rect;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.View;
import android.view.ViewGroup;

import java.lang.ref.WeakReference;
import java.util.Iterator;
import java.util.WeakHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;

/**
 * CoreSurface LivingFlow & Surgical Recents Guard Hook for com.miui.home (HyperOS Launcher).
 *
 * Production hardening:
 * - Tracks all attached CellLayouts / Workspaces and selects ONLY the currently visible
 *   home page (covering screen center via getGlobalVisibleRect) on Lockscreen -> Home unlock.
 * - Cancels prior child springs on rapid unlock & guarantees full alpha/scale/translation settle.
 * - Fast-path Recents class-cached visibility check (zero per-call String allocation).
 */
public final class LivingFlowHomeHook {
    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final LuminousShaderEngine shaderEngine;
    private final SurgicalBlurGuardHook blurGuard;
    private final TelemetryReporter telemetry;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private volatile boolean contextBootstrapped = false;
    private final CopyOnWriteArrayList<WeakReference<ViewGroup>> cellLayouts = new CopyOnWriteArrayList<>();
    private final WeakHashMap<View, SpringPhysics> childSprings = new WeakHashMap<>();
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
                    if (!isMainThread() || !(param.thisObject instanceof View)) {
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
                    if (!isMainThread() || !(param.thisObject instanceof View)) {
                        return;
                    }
                    View view = (View) param.thisObject;
                    if (blurGuard.isRecentsClass(view.getClass())) {
                        blurGuard.sanitizeRecentsViewIfNeeded(view);
                    }
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
                        mainHandler.post(LivingFlowHomeHook.this::triggerLockscreenToHomeCascade);
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
            if (cls.contains("shortcutandwidgetcontainer") || cls.contains("celllayout")) {
                addCellLayoutIfNew((ViewGroup) view);
            }
        }

        if (cls.contains("folder") && (cls.contains("content") || cls.contains("background") || cls.contains("container"))) {
            shaderEngine.decorateView(view, 28.0f);
        }
    }

    private void addCellLayoutIfNew(ViewGroup vg) {
        Iterator<WeakReference<ViewGroup>> it = cellLayouts.iterator();
        while (it.hasNext()) {
            WeakReference<ViewGroup> ref = it.next();
            ViewGroup existing = ref.get();
            if (existing == null || !existing.isAttachedToWindow()) {
                cellLayouts.remove(ref);
            } else if (existing == vg) {
                return;
            }
        }
        cellLayouts.add(new WeakReference<>(vg));
    }

    private ViewGroup findActiveVisiblePage() {
        Rect rect = new Rect();
        ViewGroup fallback = null;
        for (WeakReference<ViewGroup> ref : cellLayouts) {
            ViewGroup vg = ref.get();
            if (vg == null || !vg.isAttachedToWindow()) {
                cellLayouts.remove(ref);
                continue;
            }
            if (!vg.isShown() || vg.getChildCount() < 2) {
                continue;
            }
            if (vg.getResources() == null) {
                continue;
            }
            DisplayMetrics dm = vg.getResources().getDisplayMetrics();
            if (vg.getGlobalVisibleRect(rect)) {
                int centerX = dm.widthPixels / 2;
                int centerY = dm.heightPixels / 2;
                if (rect.contains(centerX, centerY)) {
                    return vg;
                }
                if (fallback == null && rect.width() > dm.widthPixels / 3) {
                    fallback = vg;
                }
            }
        }
        return fallback;
    }

    private void triggerLockscreenToHomeCascade() {
        if (!config.isLivingFlow() || !isMainThread()) {
            return;
        }
        long now = System.currentTimeMillis();
        if (now - lastUnlockAnimMs < 450L) {
            return;
        }
        lastUnlockAnimMs = now;

        ViewGroup targetContainer = findActiveVisiblePage();
        if (targetContainer == null) {
            return;
        }

        try {
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
                SpringPhysics prev = childSprings.remove(child);
                if (prev != null) {
                    prev.cancel();
                }

                float cx = child.getX() + child.getWidth() * 0.5f;
                float cy = child.getY() + child.getHeight() * 0.5f;
                float dx = cx - centerX;
                float dy = cy - centerY;
                float normDist = Math.min(1.0f, (float) Math.hypot(dx, dy) / maxDist);

                final float startTx = dx * 0.085f;
                final float startTy = dy * 0.085f + 16.0f;
                long delayMs = (long) (normDist * 70.0f);

                child.setAlpha(0.24f);
                child.setScaleX(0.85f);
                child.setScaleY(0.85f);
                child.setTranslationX(startTx);
                child.setTranslationY(startTy);

                mainHandler.postDelayed(() -> {
                    if (!child.isAttachedToWindow()) {
                        resetChildTransform(child);
                        return;
                    }
                    SpringPhysics spring = new SpringPhysics(0.0f, 340.0f, 0.76f, 0.002f, progress -> {
                        float p = Math.max(0.0f, Math.min(1.10f, progress));
                        float scale = 0.85f + 0.15f * p;
                        child.setScaleX(scale);
                        child.setScaleY(scale);
                        child.setTranslationX(startTx * (1.0f - p));
                        child.setTranslationY(startTy * (1.0f - p));
                        child.setAlpha(Math.min(1.0f, 0.24f + 0.76f * p));
                    }, () -> {
                        childSprings.remove(child);
                        resetChildTransform(child);
                    });
                    childSprings.put(child, spring);
                    spring.animateTo(1.0f, 1.8f);
                }, delayMs);

                // Hard safety net: guarantees icons can never remain dimmed/offset
                mainHandler.postDelayed(() -> {
                    if (!childSprings.containsKey(child)) {
                        resetChildTransform(child);
                    }
                }, delayMs + 650L);
            }
            telemetry.incFlowAnimations();
        } catch (Throwable ignored) {
        }
    }

    private static void resetChildTransform(View child) {
        child.setScaleX(1.0f);
        child.setScaleY(1.0f);
        child.setTranslationX(0.0f);
        child.setTranslationY(0.0f);
        child.setAlpha(1.0f);
    }

    private static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }
}
