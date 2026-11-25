package org.mystivara.coresurface.engine;

import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;

import java.lang.reflect.Method;
import java.util.concurrent.ConcurrentHashMap;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * Surgical HyperOS 3 Toast Pop-up & Black Recent Apps Guard.
 *
 * Production hardening:
 * - Caches MIUI reflection Method handles (zero repeated reflection lookups).
 * - Strips BOTH standard Android blurBehindRadius/FLAG_BLUR_BEHIND AND proprietary
 *   HyperOS View blur setters (setMiBackgroundBlurMode / setMiBackgroundBlurRadius /
 *   setMiViewBlurMode) both at WindowManagerGlobal.addView/updateViewLayout AND
 *   via post-attach runnable so MiuiToast cannot re-enable blur 1 frame later.
 * - Class-caches Recents view detection so visibility callbacks cost ~5ns.
 */
public final class SurgicalBlurGuardHook {
    private static final int RECENTS_NO = 0;
    private static final int RECENTS_YES = 1;

    private final EngineConfig config;
    private final TelemetryReporter telemetry;
    private final ConcurrentHashMap<Class<?>, Integer> recentsClassCache = new ConcurrentHashMap<>();

    private volatile boolean miBlurMethodsResolved = false;
    private Method mSetMiBackgroundBlurMode;
    private Method mSetMiBackgroundBlurRadius;
    private Method mSetMiViewBlurMode;

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

    public boolean isRecentsClass(Class<?> clazz) {
        Integer cached = recentsClassCache.get(clazz);
        if (cached != null) {
            return cached == RECENTS_YES;
        }
        String cls = clazz.getName().toLowerCase();
        boolean match = cls.contains("recents") || cls.contains("taskstack") || cls.contains("overview");
        recentsClassCache.put(clazz, match ? RECENTS_YES : RECENTS_NO);
        return match;
    }

    public void sanitizeRecentsViewIfNeeded(View view) {
        if (!config.isSurgicalGuard() || view == null || !isRecentsClass(view.getClass())) {
            return;
        }
        try {
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

    private void sanitizeToastWindow(final View view, WindowManager.LayoutParams lp) {
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
            if (clearMiBlurRecursive(view, 0)) {
                modified = true;
            }
            // Post-attach sweep in case HyperOS MiuiToast applies blur right after addView()
            view.post(() -> {
                if (config.isSurgicalGuard()) {
                    clearMiBlurRecursive(view, 0);
                }
            });
            if (modified) {
                telemetry.incToastsGuarded();
            }
        } catch (Throwable ignored) {
        }
    }

    private void resolveMiBlurMethodsOnce() {
        if (miBlurMethodsResolved) {
            return;
        }
        miBlurMethodsResolved = true;
        mSetMiBackgroundBlurMode = findViewIntMethod("setMiBackgroundBlurMode");
        mSetMiBackgroundBlurRadius = findViewIntMethod("setMiBackgroundBlurRadius");
        mSetMiViewBlurMode = findViewIntMethod("setMiViewBlurMode");
    }

    private static Method findViewIntMethod(String name) {
        try {
            return View.class.getMethod(name, int.class);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private boolean clearMiBlurRecursive(View view, int depth) {
        if (view == null || depth > 4) {
            return false;
        }
        resolveMiBlurMethodsOnce();
        boolean cleared = false;
        try {
            if (mSetMiBackgroundBlurMode != null) {
                mSetMiBackgroundBlurMode.invoke(view, 0);
                cleared = true;
            }
            if (mSetMiBackgroundBlurRadius != null) {
                mSetMiBackgroundBlurRadius.invoke(view, 0);
                cleared = true;
            }
            if (mSetMiViewBlurMode != null) {
                mSetMiViewBlurMode.invoke(view, 0);
                cleared = true;
            }
        } catch (Throwable ignored) {
        }
        if (view instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) view;
            int count = Math.min(vg.getChildCount(), 16);
            for (int i = 0; i < count; i++) {
                if (clearMiBlurRecursive(vg.getChildAt(i), depth + 1)) {
                    cleared = true;
                }
            }
        }
        return cleared;
    }
}
