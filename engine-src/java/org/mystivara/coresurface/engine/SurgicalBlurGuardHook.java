package org.mystivara.coresurface.engine;

import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;

import java.lang.reflect.Method;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * Surgical HyperOS 3 Toast Pop-up & Black Recent Apps Guard.
 *
 * Root cause on HyperOS 3 mid-range GPUs when Advanced Textures is enabled:
 * 1. Toast / Transient windows receive an oversized backdrop blur region (blurBehindRadius /
 *    MiBackgroundBlurMode), bloating Toast boxes across the screen.
 * 2. Recent Apps (RecentsView / Overview) falls back to an opaque black scrim over wallpaper
 *    when the vendor backdrop blur pipeline rejects the Recents layer.
 *
 * This hook surgically sanitizes ONLY Toast windows and opaque-black Recents scrims
 * without disabling Control Center / Notification Shade / Folder blur.
 */
public final class SurgicalBlurGuardHook {
    private final EngineConfig config;
    private final TelemetryReporter telemetry;

    public SurgicalBlurGuardHook(EngineConfig config, TelemetryReporter telemetry) {
        this.config = config;
        this.telemetry = telemetry;
    }

    public void installWindowToastGuard(ClassLoader cl) {
        try {
            Class<?> wmgClass = XposedHelpers.findClassIfExists("android.view.WindowManagerGlobal", cl);
            if (wmgClass == null) {
                return;
            }

            XC_MethodHook windowHook = new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (!config.isSurgicalGuard()) {
                        return;
                    }
                    if (param.args == null || param.args.length < 2) {
                        return;
                    }
                    if (!(param.args[0] instanceof View) || !(param.args[1] instanceof ViewGroup.LayoutParams)) {
                        return;
                    }
                    View view = (View) param.args[0];
                    ViewGroup.LayoutParams rawLp = (ViewGroup.LayoutParams) param.args[1];
                    if (!(rawLp instanceof WindowManager.LayoutParams)) {
                        return;
                    }
                    WindowManager.LayoutParams lp = (WindowManager.LayoutParams) rawLp;
                    if (isToastWindow(view, lp)) {
                        sanitizeToastWindow(view, lp);
                    }
                }
            };

            XposedBridge.hookAllMethods(wmgClass, "addView", windowHook);
            XposedBridge.hookAllMethods(wmgClass, "updateViewLayout", windowHook);
            telemetry.recordHookBound("ToastGuard");
        } catch (Throwable ignored) {
        }
    }

    public void sanitizeRecentsViewIfNeeded(View view) {
        if (!config.isSurgicalGuard() || view == null) {
            return;
        }
        try {
            String cls = view.getClass().getName().toLowerCase();
            if (!cls.contains("recents") && !cls.contains("taskstack") && !cls.contains("overview")) {
                return;
            }
            Drawable bg = view.getBackground();
            if (bg instanceof ColorDrawable) {
                int color = ((ColorDrawable) bg).getColor();
                int alpha = Color.alpha(color);
                int r = Color.red(color);
                int g = Color.green(color);
                int b = Color.blue(color);
                // Detect broken HyperOS 3 opaque/near-opaque black fallback scrim
                if (alpha >= 210 && r <= 24 && g <= 24 && b <= 24) {
                    view.setBackgroundColor(Color.argb(68, 12, 16, 24));
                    telemetry.incRecentsGuarded();
                }
            }
        } catch (Throwable ignored) {
        }
    }

    @SuppressWarnings("deprecation")
    private boolean isToastWindow(View view, WindowManager.LayoutParams lp) {
        if (lp.type == WindowManager.LayoutParams.TYPE_TOAST) {
            return true;
        }
        CharSequence title = lp.getTitle();
        if (title != null) {
            String t = title.toString().toLowerCase();
            if (t.contains("toast") || t.contains("transientnotification")) {
                return true;
            }
        }
        String cls = view.getClass().getName().toLowerCase();
        return cls.contains("toast");
    }

    private void sanitizeToastWindow(View view, WindowManager.LayoutParams lp) {
        try {
            boolean modified = false;
            if ((lp.flags & WindowManager.LayoutParams.FLAG_BLUR_BEHIND) != 0) {
                lp.flags &= ~WindowManager.LayoutParams.FLAG_BLUR_BEHIND;
                modified = true;
            }
            if (Build.VERSION.SDK_INT >= 31 && lp.getBlurBehindRadius() > 0) {
                lp.setBlurBehindRadius(0);
                modified = true;
            }
            clearMiBlurRecursive(view);
            if (modified) {
                telemetry.incToastsGuarded();
            }
        } catch (Throwable ignored) {
        }
    }

    private void clearMiBlurRecursive(View view) {
        if (view == null) {
            return;
        }
        try {
            Method m = view.getClass().getMethod("setMiBackgroundBlurMode", int.class);
            m.invoke(view, 0);
        } catch (Throwable ignored) {
        }
        if (view instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) view;
            int count = Math.min(vg.getChildCount(), 16);
            for (int i = 0; i < count; i++) {
                clearMiBlurRecursive(vg.getChildAt(i));
            }
        }
    }
}
