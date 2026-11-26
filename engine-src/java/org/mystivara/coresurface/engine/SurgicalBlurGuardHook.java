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
 * Surgical HyperOS 3 Toast Pop-up, Black Recent Apps & -1 Screen (App Vault) Guard.
 *
 * Ultra-lightweight zero-allocation hot-path:
 * - Single unified ConcurrentHashMap<Class<?>, Integer> bitmask cache (RECENTS | MINUS_ONE | TOAST)
 *   eliminates ALL per-call getName().toLowerCase() String allocations on View blur setters & layouts.
 * - Single unified WindowManagerGlobal trampoline inside Launcher (handles Toast + Recents + -1 Screen
 *   in one hook instead of two duplicate trampolines).
 * - Fast window-type early exit rejects regular app/status/nav/wallpaper windows in 1 integer check.
 * - Protected by DeviceBugGuard circuit breakers.
 */
public final class SurgicalBlurGuardHook {
    private static final int MASK_RECENTS = 1;
    private static final int MASK_MINUS_ONE = 2;
    private static final int MASK_TOAST = 4;

    private static final String[] HOME_RECENTS_BLUR_CLASSES = new String[] {
            "com.miui.home.recents.util.BlurUtils",
            "com.miui.home.recents.views.RecentsContainer",
            "com.miui.home.recents.NavStubView"
    };

    private final EngineConfig config;
    private final DeviceBugGuard bugGuard;
    private final TelemetryReporter telemetry;
    private final ConcurrentHashMap<Class<?>, Integer> classMaskCache = new ConcurrentHashMap<>();

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
                        if (!config.isSurgicalGuard() || param.args == null || param.args.length < 2) {
                            return;
                        }
                        if (!(param.args[0] instanceof View) || !(param.args[1] instanceof WindowManager.LayoutParams)) {
                            return;
                        }
                        View view = (View) param.args[0];
                        WindowManager.LayoutParams lp = (WindowManager.LayoutParams) param.args[1];
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
     * Installed strictly inside com.miui.home / POCO Launcher:
     * - Unified single WindowManagerGlobal hook (handles Toast + Recents + -1 Screen in 1 trampoline)
     * - Recents-specific BlurUtils query guard (leaves Folder/Wallpaper/Workspace untouched)
     * - Cached-bitmask MIUI View blur guard (0 String allocations after first sight of class)
     */
    public void installHomeRecentsGuard(ClassLoader cl) {
        int hooked = 0;

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
                if (m.getReturnType() == boolean.class && isCompleteBlurQuery(m.getName())) {
                    if (hookReturnFalseWhenGuarded(m)) {
                        hooked++;
                    }
                }
            }
        }

        if (bugGuard.hasMiBlurApi()) {
            hooked += hookViewMiBlurForHome("setMiBackgroundBlurMode");
            hooked += hookViewMiBlurForHome("setMiViewBlurMode");
            hooked += hookViewPassWindowBlurForHome();
        }

        // Unified single WindowManagerGlobal hook in Launcher (Toast + Recents + MinusOne)
        try {
            Class<?> wmgClass = XposedHelpers.findClassIfExists("android.view.WindowManagerGlobal", cl);
            if (wmgClass != null) {
                XC_MethodHook homeWinHook = new XC_MethodHook() {
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
                            if (isToastWindow(view, lp)) {
                                sanitizeToastWindow(view, lp);
                                return;
                            }
                            if (isRecentsOrMinusOneWindow(view, lp)) {
                                if (stripWindowBlurBehind(lp)) {
                                    telemetry.incRecentsGuarded();
                                }
                            }
                        } catch (Throwable ignored) {
                            bugGuard.recordHookFault("RecentsWinGuard");
                        }
                    }
                };
                XposedBridge.hookAllMethods(wmgClass, "addView", homeWinHook);
                XposedBridge.hookAllMethods(wmgClass, "updateViewLayout", homeWinHook);
                telemetry.recordHookBound("ToastGuard");
                hooked++;
            }
        } catch (Throwable ignored) {
        }

        if (hooked > 0) {
            telemetry.recordHookBound("RecentsGuard");
        }
    }

    /**
     * Installed strictly inside com.mi.android.globalminusscreen & com.miui.personalassistant (-1 Screen).
     * Fixes solid #000000 black -1 Screen backdrop when HyperOS 3 Advanced Textures is enabled on
     * mid-range GPUs by disabling broken cross-process pass-window blur and opaque black scrims.
     */
    public void installMinusOneAppGuard(ClassLoader cl) {
        int hooked = 0;
        try {
            Class<?> wmgClass = XposedHelpers.findClassIfExists("android.view.WindowManagerGlobal", cl);
            if (wmgClass != null) {
                XC_MethodHook minusWinHook = new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        if (bugGuard.isHookTripped("MinusOneWinGuard")) {
                            return;
                        }
                        try {
                            if (!config.isSurgicalGuard() || param.args == null || param.args.length < 2) {
                                return;
                            }
                            if (!(param.args[0] instanceof View) || !(param.args[1] instanceof WindowManager.LayoutParams)) {
                                return;
                            }
                            View root = (View) param.args[0];
                            WindowManager.LayoutParams lp = (WindowManager.LayoutParams) param.args[1];
                            boolean stripped = stripWindowBlurBehind(lp);
                            if (sanitizeOpaqueBlackBackdrop(root)) {
                                stripped = true;
                            }
                            if (stripped) {
                                telemetry.incRecentsGuarded();
                            }
                        } catch (Throwable ignored) {
                            bugGuard.recordHookFault("MinusOneWinGuard");
                        }
                    }
                };
                XposedBridge.hookAllMethods(wmgClass, "addView", minusWinHook);
                XposedBridge.hookAllMethods(wmgClass, "updateViewLayout", minusWinHook);
                hooked++;
            }
        } catch (Throwable ignored) {
        }

        if (bugGuard.hasMiBlurApi()) {
            hooked += hookMinusOneMiBlurMode("setMiBackgroundBlurMode");
            hooked += hookMinusOneMiBlurMode("setMiViewBlurMode");
            hooked += hookMinusOnePassWindowBlur();
        }

        if (hooked > 0) {
            telemetry.recordHookBound("MinusOneGuard");
            telemetry.recordOsBugMitigated("HOS3_MINUS_ONE_BLACK");
        }
    }

    private static boolean stripWindowBlurBehind(WindowManager.LayoutParams lp) {
        boolean stripped = false;
        if ((lp.flags & WindowManager.LayoutParams.FLAG_BLUR_BEHIND) != 0) {
            lp.flags &= ~WindowManager.LayoutParams.FLAG_BLUR_BEHIND;
            stripped = true;
        }
        if (Build.VERSION.SDK_INT >= 31 && lp.getBlurBehindRadius() > 0) {
            lp.setBlurBehindRadius(0);
            stripped = true;
        }
        return stripped;
    }

    private int hookMinusOneMiBlurMode(String methodName) {
        try {
            Method m = View.class.getMethod(methodName, int.class);
            XposedBridge.hookMethod(m, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("MinusOneMiBlur") || !config.isSurgicalGuardFast()) {
                        return;
                    }
                    try {
                        if (param.args != null && param.args.length >= 1
                                && param.args[0] instanceof Integer && ((Integer) param.args[0]) != 0) {
                            param.args[0] = 0;
                            telemetry.incRecentsGuarded();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("MinusOneMiBlur");
                    }
                }
            });
            return 1;
        } catch (Throwable ignored) {
            return 0;
        }
    }

    private int hookMinusOnePassWindowBlur() {
        try {
            Method m = View.class.getMethod("setPassWindowBlurEnabled", boolean.class);
            XposedBridge.hookMethod(m, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("MinusOnePassBlur") || !config.isSurgicalGuardFast()) {
                        return;
                    }
                    try {
                        if (param.args != null && param.args.length >= 1 && Boolean.TRUE.equals(param.args[0])) {
                            param.args[0] = Boolean.FALSE;
                            telemetry.incRecentsGuarded();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("MinusOnePassBlur");
                    }
                }
            });
            return 1;
        } catch (Throwable ignored) {
            return 0;
        }
    }

    private int hookViewPassWindowBlurForHome() {
        try {
            Method m = View.class.getMethod("setPassWindowBlurEnabled", boolean.class);
            XposedBridge.hookMethod(m, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("HomePassBlur") || !config.isSurgicalGuardFast()) {
                        return;
                    }
                    try {
                        if (!(param.thisObject instanceof View) || param.args == null
                                || param.args.length < 1 || !Boolean.TRUE.equals(param.args[0])) {
                            return;
                        }
                        if ((getClassMask(param.thisObject.getClass()) & (MASK_RECENTS | MASK_MINUS_ONE)) != 0) {
                            param.args[0] = Boolean.FALSE;
                            telemetry.incRecentsGuarded();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault("HomePassBlur");
                    }
                }
            });
            return 1;
        } catch (Throwable ignored) {
            return 0;
        }
    }

    private int hookViewMiBlurForHome(String methodName) {
        try {
            Method m = View.class.getMethod(methodName, int.class);
            XposedBridge.hookMethod(m, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("RecentsMiBlur") || !config.isSurgicalGuardFast()) {
                        return;
                    }
                    try {
                        if (!(param.thisObject instanceof View) || param.args == null || param.args.length < 1) {
                            return;
                        }
                        Object arg = param.args[0];
                        if (!(arg instanceof Integer) || ((Integer) arg) == 0) {
                            return;
                        }
                        if ((getClassMask(param.thisObject.getClass()) & (MASK_RECENTS | MASK_MINUS_ONE)) != 0) {
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

    private static boolean sanitizeOpaqueBlackBackdrop(View view) {
        if (view == null) {
            return false;
        }
        try {
            Drawable bg = view.getBackground();
            if (bg instanceof ColorDrawable) {
                int color = ((ColorDrawable) bg).getColor();
                int alpha = Color.alpha(color);
                int r = Color.red(color);
                int g = Color.green(color);
                int b = Color.blue(color);
                if (alpha >= 230 && r <= 18 && g <= 18 && b <= 18) {
                    view.setBackgroundColor(Color.argb(110, 14, 18, 26));
                    return true;
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private boolean hookReturnFalseWhenGuarded(Method m) {
        try {
            XposedBridge.hookMethod(m, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped("RecentsCompleteBlur") || !config.isSurgicalGuardFast()) {
                        return;
                    }
                    try {
                        param.setResult(Boolean.FALSE);
                        telemetry.incRecentsGuarded();
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

    private int getClassMask(Class<?> clazz) {
        Integer cached = classMaskCache.get(clazz);
        if (cached != null) {
            return cached;
        }
        String cls = clazz.getName().toLowerCase(Locale.ROOT);
        int mask = 0;

        if (cls.contains("toast")) {
            mask |= MASK_TOAST;
        }

        boolean isMinusOne = cls.contains("minusone")
                || cls.contains("minus_one")
                || cls.contains("personalassistant")
                || cls.contains("assistant")
                || cls.contains("appvault")
                || cls.contains("blurmask")
                || cls.contains("launcher.overlay.");
        if (isMinusOne) {
            mask |= MASK_MINUS_ONE;
        }

        // Explicitly never classify Folder, -1 Screen, Wallpaper, Workspace, DragLayer,
        // Control Center, QS, or Notification blur views as Recents
        boolean excluded = isMinusOne
                || cls.contains("folder")
                || cls.contains("wallpaper")
                || cls.contains("workspace")
                || cls.contains("draglayer")
                || cls.contains("controlcenter")
                || cls.contains("notification")
                || cls.contains(".qs.");
        if (!excluded
                && (cls.contains("recents")
                || cls.contains("taskstack")
                || cls.contains("overview")
                || cls.contains("navstub"))) {
            mask |= MASK_RECENTS;
        }

        classMaskCache.put(clazz, mask);
        return mask;
    }

    public boolean isRecentsClass(Class<?> clazz) {
        return (getClassMask(clazz) & MASK_RECENTS) != 0;
    }

    public void sanitizeRecentsViewIfNeeded(View view) {
        if (!config.isSurgicalGuardFast() || view == null || !isRecentsClass(view.getClass())) {
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

    private boolean isRecentsOrMinusOneWindow(View view, WindowManager.LayoutParams lp) {
        if ((getClassMask(view.getClass()) & (MASK_RECENTS | MASK_MINUS_ONE)) != 0) {
            return true;
        }
        CharSequence title = lp.getTitle();
        if (title != null && title.length() > 0) {
            String t = title.toString().toLowerCase(Locale.ROOT);
            return t.contains("recents") || t.contains("overview")
                    || t.contains("minusone") || t.contains("minus_one")
                    || t.contains("personalassistant") || t.contains("assistant")
                    || t.contains("appvault") || t.contains("globalminusscreen");
        }
        return false;
    }

    @SuppressWarnings("deprecation")
    private boolean isToastWindow(View view, WindowManager.LayoutParams lp) {
        int type = lp.type;
        if (type == WindowManager.LayoutParams.TYPE_TOAST) {
            return true;
        }
        // Fast reject standard non-toast window types with 0 String allocations
        if ((type >= WindowManager.LayoutParams.FIRST_APPLICATION_WINDOW
                && type <= WindowManager.LayoutParams.LAST_APPLICATION_WINDOW)
                || type == WindowManager.LayoutParams.TYPE_WALLPAPER
                || type == WindowManager.LayoutParams.TYPE_INPUT_METHOD
                || type == WindowManager.LayoutParams.TYPE_STATUS_BAR) {
            return false;
        }
        if ((getClassMask(view.getClass()) & MASK_TOAST) != 0) {
            return true;
        }
        CharSequence title = lp.getTitle();
        if (title != null && title.length() > 0) {
            String t = title.toString().toLowerCase(Locale.ROOT);
            return t.contains("toast") || t.contains("transientnotification");
        }
        return false;
    }

    private void sanitizeToastWindow(final View view, WindowManager.LayoutParams lp) {
        try {
            boolean modified = stripWindowBlurBehind(lp);
            if (clearMiBlurRecursive(view, 0)) {
                modified = true;
            }
            view.post(() -> {
                if (config.isSurgicalGuardFast()) {
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
