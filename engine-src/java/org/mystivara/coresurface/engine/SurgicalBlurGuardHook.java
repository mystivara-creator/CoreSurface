package org.mystivara.coresurface.engine;

import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * Surgical HyperOS 3 Toast Pop-up & Black Recent Apps Guard.
 *
 * Root-cause fix for HyperOS 3 black Recent Apps when Advanced Textures is enabled:
 * - In com.miui.home, Advanced Textures switches BlurUtils to "complete / pass-window"
 *   real-time blur (isUseCompleteBlurOnDev / getBlurType >= 2 / MiBackgroundBlur on
 *   RecentsContainer/NavStubView), which fails to sample the wallpaper on mid-range GPUs
 *   and renders a solid black surface.
 * - installHomeRecentsGuard() surgically steers MiuiHome's Recents back to Xiaomi's stable
 *   standard wallpaper blur WITHOUT breaking Folder blur or Control Center blur.
 * - installWindowToastGuard() strips broken Toast window blur & MIUI View blur setters.
 * - Every hook callback is protected by DeviceBugGuard circuit breakers.
 */
public final class SurgicalBlurGuardHook {
    private static final int RECENTS_NO = 0;
    private static final int RECENTS_YES = 1;

    // Strictly Recents-scoped classes ONLY — NEVER hook com.miui.home.launcher.common.BlurUtils
    // globally because it drives -1 Screen (App Vault) and Folder open/close blur transitions;
    // downgrading getBlurType()/isUseCompleteBlurOnDev() globally causes black-backdrop blinks.
    private static final String[] HOME_RECENTS_BLUR_CLASSES = new String[] {
            "com.miui.home.recents.util.BlurUtils",
            "com.miui.home.recents.views.RecentsContainer",
            "com.miui.home.recents.NavStubView"
    };

    private final EngineConfig config;
    private final DeviceBugGuard bugGuard;
    private final TelemetryReporter telemetry;
    private final ConcurrentHashMap<Class<?>, Integer> recentsClassCache = new ConcurrentHashMap<>();

    private volatile boolean miBlurMethodsResolved = false;
    private Method mSetMiBackgroundBlurMode;
    private Method mSetMiBackgroundBlurRadius;
    private Method mSetMiViewBlurMode;

    public SurgicalBlurGuardHook(EngineConfig config, DeviceBugGuard bugGuard, TelemetryReporter telemetry) {
        this.config = config;
        this.bugGuard = bugGuard;
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
                    if (bugGuard.isHookTripped("ToastGuard")) {
                        return;
                    }
                    try {
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
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("ToastGuard");
                    }
                }
            };

            XposedBridge.hookAllMethods(wmgClass, "addView", windowHook);
            XposedBridge.hookAllMethods(wmgClass, "updateViewLayout", windowHook);
            telemetry.recordHookBound("ToastGuard");
        } catch (Throwable ignored) {
        }
    }

    /**
     * Installed strictly inside com.miui.home to fix HyperOS 3 black Recent Apps under
     * Advanced Textures while leaving Control Center, Folder, and -1 Screen (App Vault)
     * blur transitions 100% untouched.
     */
    public void installHomeRecentsGuard(ClassLoader cl) {
        int hooked = 0;

        // 1. Steer ONLY Recents-specific blur queries away from broken pass-window Recents blur
        for (String clsName : HOME_RECENTS_BLUR_CLASSES) {
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
                if (Modifier.isAbstract(m.getModifiers())) {
                    continue;
                }
                String name = m.getName();
                Class<?> ret = m.getReturnType();
                if (ret == boolean.class && isCompleteBlurQuery(name)) {
                    if (hookReturnFalseWhenGuarded(m)) {
                        hooked++;
                    }
                }
            }
        }

        // 2. Intercept MIUI View background blur setters ONLY on true Recents/Overview/NavStub views
        //    (explicitly excludes Folder, -1 Screen / App Vault, Wallpaper, Workspace & Control Center;
        //    skipped cleanly when MiBlur API is absent)
        if (bugGuard.hasMiBlurApi()) {
            hooked += hookViewMiBlurForRecents("setMiBackgroundBlurMode");
            hooked += hookViewMiBlurForRecents("setMiViewBlurMode");
        }

        // 3. Guard MiuiHome Recents & -1 Screen (App Vault / MinusOne) cross-window FLAG_BLUR_BEHIND
        //    so SurfaceFlinger never drops the wallpaper layer to solid #000000 black under Advanced Textures.
        try {
            Class<?> wmgClass = XposedHelpers.findClassIfExists("android.view.WindowManagerGlobal", cl);
            if (wmgClass != null) {
                XC_MethodHook recentsWinHook = new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        if (bugGuard.isHookTripped("RecentsWinGuard")) {
                            return;
                        }
                        try {
                            if (!config.isSurgicalGuard() || param.args == null || param.args.length < 2) {
                                return;
                            }
                            if (!(param.args[0] instanceof View) || !(param.args[1] instanceof WindowManager.LayoutParams)) {
                                return;
                            }
                            View view = (View) param.args[0];
                            WindowManager.LayoutParams lp = (WindowManager.LayoutParams) param.args[1];
                            if (isRecentsWindow(view, lp) || isMinusOneWindow(view, lp)) {
                                boolean stripped = false;
                                if ((lp.flags & WindowManager.LayoutParams.FLAG_BLUR_BEHIND) != 0) {
                                    lp.flags &= ~WindowManager.LayoutParams.FLAG_BLUR_BEHIND;
                                    stripped = true;
                                }
                                if (Build.VERSION.SDK_INT >= 31 && lp.getBlurBehindRadius() > 0) {
                                    lp.setBlurBehindRadius(0);
                                    stripped = true;
                                }
                                if (stripped) {
                                    telemetry.incRecentsGuarded();
                                }
                            }
                        } catch (Throwable ignored) {
                            bugGuard.recordHookFault("RecentsWinGuard");
                        }
                    }
                };
                XposedBridge.hookAllMethods(wmgClass, "addView", recentsWinHook);
                XposedBridge.hookAllMethods(wmgClass, "updateViewLayout", recentsWinHook);
                hooked++;
            }
        } catch (Throwable ignored) {
        }

        if (hooked > 0) {
            telemetry.recordHookBound("RecentsGuard");
        }
    }

    private boolean hookReturnFalseWhenGuarded(Method m) {
        try {
            XposedBridge.hookMethod(m, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("RecentsCompleteBlur")) {
                        return;
                    }
                    try {
                        if (config.isSurgicalGuard()) {
                            param.setResult(Boolean.FALSE);
                            telemetry.incRecentsGuarded();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("RecentsCompleteBlur");
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private int hookViewMiBlurForRecents(String methodName) {
        try {
            Method m = View.class.getMethod(methodName, int.class);
            XposedBridge.hookMethod(m, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("RecentsMiBlur")) {
                        return;
                    }
                    try {
                        if (!config.isSurgicalGuard() || !(param.thisObject instanceof View)
                                || param.args == null || param.args.length < 1) {
                            return;
                        }
                        Object arg = param.args[0];
                        if (!(arg instanceof Integer)) {
                            return;
                        }
                        int mode = (Integer) arg;
                        if (mode == 0) {
                            return;
                        }
                        View v = (View) param.thisObject;
                        Class<?> vClass = v.getClass();
                        if (isRecentsClass(vClass)) {
                            param.args[0] = 0;
                            telemetry.incRecentsGuarded();
                        } else if (mode >= 2 && isMinusOneClass(vClass)) {
                            // Mode >= 2 is pass-window cross-process blur, which drops the home
                            // wallpaper to solid #000000 black behind -1 Screen on mid-range HOS 3.
                            param.args[0] = 0;
                            telemetry.incRecentsGuarded();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("RecentsMiBlur");
                    }
                }
            });
            return 1;
        } catch (Throwable ignored) {
            return 0;
        }
    }

    private static boolean isMinusOneClass(Class<?> clazz) {
        String cls = clazz.getName().toLowerCase(Locale.ROOT);
        return cls.contains("minusone")
                || cls.contains("minus_one")
                || cls.contains("personalassistant")
                || cls.contains("appvault");
    }

    private boolean isMinusOneWindow(View view, WindowManager.LayoutParams lp) {
        if (isMinusOneClass(view.getClass())) {
            return true;
        }
        CharSequence title = lp.getTitle();
        if (title != null) {
            String t = title.toString().toLowerCase(Locale.ROOT);
            return t.contains("minusone") || t.contains("minus_one")
                    || t.contains("personalassistant") || t.contains("appvault");
        }
        return false;
    }

    public boolean isRecentsClass(Class<?> clazz) {
        Integer cached = recentsClassCache.get(clazz);
        if (cached != null) {
            return cached == RECENTS_YES;
        }
        String cls = clazz.getName().toLowerCase(Locale.ROOT);
        // Explicitly never touch Folder, -1 Screen (App Vault / MinusOne), Wallpaper, Workspace,
        // DragLayer, Control Center, QS, or Notification blur views
        boolean excluded = cls.contains("folder")
                || cls.contains("minusone")
                || cls.contains("minus_one")
                || cls.contains("personalassistant")
                || cls.contains("assistant")
                || cls.contains("appvault")
                || cls.contains("wallpaper")
                || cls.contains("workspace")
                || cls.contains("draglayer")
                || cls.contains("controlcenter")
                || cls.contains("notification")
                || cls.contains(".qs.");
        boolean match = !excluded
                && (cls.contains("recents")
                || cls.contains("taskstack")
                || cls.contains("overview")
                || cls.contains("navstub"));
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
                if (alpha >= 210 && r <= 24 && g <= 24 && b <= 24) {
                    view.setBackgroundColor(Color.argb(68, 12, 16, 24));
                    telemetry.incRecentsGuarded();
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private static boolean isCompleteBlurQuery(String methodName) {
        String lower = methodName.toLowerCase(Locale.ROOT);
        return lower.contains("completerecentsblur")
                || lower.contains("passwindowblur")
                || lower.contains("realtimeblurinrecents");
    }

    private boolean isRecentsWindow(View view, WindowManager.LayoutParams lp) {
        if (isRecentsClass(view.getClass())) {
            return true;
        }
        CharSequence title = lp.getTitle();
        if (title != null) {
            String t = title.toString().toLowerCase(Locale.ROOT);
            return t.contains("recents") || t.contains("overview");
        }
        return false;
    }

    @SuppressWarnings("deprecation")
    private boolean isToastWindow(View view, WindowManager.LayoutParams lp) {
        if (lp.type == WindowManager.LayoutParams.TYPE_TOAST) {
            return true;
        }
        CharSequence title = lp.getTitle();
        if (title != null) {
            String t = title.toString().toLowerCase(Locale.ROOT);
            if (t.contains("toast") || t.contains("transientnotification")) {
                return true;
            }
        }
        String cls = view.getClass().getName().toLowerCase(Locale.ROOT);
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

    private static Class<?> safeFindClass(String className, ClassLoader cl) {
        try {
            return XposedHelpers.findClassIfExists(className, cl);
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
