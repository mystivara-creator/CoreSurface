package org.mystivara.coresurface.engine;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;

import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * CoreSurface Launcher Physics Choreography Engine (com.miui.home / POCO Launcher).
 *
 * Strictly layout-safe & zero-desync design:
 * 1. App Open / App Close / Swipe-Up-to-Home (`RectFSpringAnim`):
 *    - Reflectively caches spatial spring fields once per class (zero per-frame reflection).
 *    - Tunes ONLY X/Y/Width/Scale SpringForce damping & stiffness + finger velocity handoff
 *      while leaving Alpha, CornerRadius, and Workspace layout scale 100% owned by Launcher
 *      (eliminates shrunk-Workspace vs Hotseat/Search layout desync).
 * 2. Clean Bouncy Lock Screen -> Home Screen Spring (`ios` profile):
 *    - Strict state machine: arms ONLY on true screen-off/Keyguard lock and disarms automatically
 *      within 400ms if the user unlocked into another app (NEVER randomly spawns on Home press).
 *    - NEVER drops View alpha (zero "tiba-tiba spawn" flash/pop) and NEVER mutates Workspace scale.
 *    - Animates visible CellLayout icons/widgets & Hotseat dock together with synchronized
 *      CoreSpringSolver elastic bounce (zeta=0.58), and guarantees exact identity cleanup on onPause.
 * 3. Interruptible Folder Open/Close Choreography (`CoreSurfaceChoreographer`).
 */
public final class LauncherChoreographyHook {
    private static final String CIRCUIT_RECTF = "LauncherRectF";
    private static final String CIRCUIT_FOLDER = "LauncherFolder";
    private static final String CIRCUIT_UNLOCK = "LauncherUnlockBounce";

    private static final long UNLOCK_ARM_EXPIRE_MS = 450L;
    private static final long UNLOCK_DEBOUNCE_MS = 1000L;
    private static final int MAX_UNLOCK_ICONS = 32;

    private static final String[] RECTF_CLASSES = new String[] {
            "com.miui.home.recents.util.RectFSpringAnim",
            "com.miui.home.recents.util.RectFSpringAnimBase"
    };

    private static final String[] FOLDER_CLASSES = new String[] {
            "com.miui.home.launcher.Folder",
            "com.miui.home.launcher.FolderCling",
            "com.miui.home.launcher.folder.FolderSheet"
    };

    private static final class CachedRectFFields {
        final Field[] posSpringFields;
        final Field[] scaleSpringFields;

        CachedRectFFields(Field[] pos, Field[] scale) {
            this.posSpringFields = pos;
            this.scaleSpringFields = scale;
        }
    }

    private final FolmePhysicsHook specHub;
    private final CoreSurfaceChoreographer choreographer;
    private final DeviceBugGuard bugGuard;
    private final TelemetryReporter telemetry;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ConcurrentHashMap<Class<?>, CachedRectFFields> fieldCache = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Class<?>, Method> springGetterCache = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Class<?>, Method> dampSetterCache = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Class<?>, Method> stiffSetterCache = new ConcurrentHashMap<>();

    private final AtomicBoolean receiverRegistered = new AtomicBoolean(false);
    private volatile WeakReference<Activity> launcherActivityRef = new WeakReference<>(null);
    private volatile boolean launcherResumed = false;
    private volatile boolean armedForLockscreenUnlock = false;
    private volatile long unlockTriggeredUptimeMs = 0L;

    // If user unlocked into another app (Launcher never became active within 450ms),
    // automatically disarm so pressing Home later NEVER spawns a fake unlock animation.
    private final Runnable disarmUnlockRunnable = new Runnable() {
        @Override
        public void run() {
            armedForLockscreenUnlock = false;
        }
    };

    public LauncherChoreographyHook(FolmePhysicsHook specHub, CoreSurfaceChoreographer choreographer,
                                    DeviceBugGuard bugGuard, TelemetryReporter telemetry) {
        this.specHub = specHub;
        this.choreographer = choreographer;
        this.bugGuard = bugGuard;
        this.telemetry = telemetry;
    }

    public int install(ClassLoader cl) {
        if (cl == null) {
            return 0;
        }
        int hooked = 0;
        hooked += installRectFSpringHooks(cl);
        hooked += installFolderChoreographyHooks(cl);
        hooked += installUniversalActivityHooks();
        if (hooked > 0) {
            telemetry.addFolmeHooksBound(hooked);
            telemetry.recordHookBound("LauncherChoreography");
        }
        return hooked;
    }

    // -------------------------------------------------------------------------
    // 1. Strict Lock Screen -> Home Screen Unlock State Machine (Zero Pop / Zero Random Spawn)
    // -------------------------------------------------------------------------

    private int installUniversalActivityHooks() {
        int hooked = 0;
        try {
            XposedBridge.hookAllMethods(Activity.class, "onResume", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!(param.thisObject instanceof Activity)) {
                        return;
                    }
                    Activity act = (Activity) param.thisObject;
                    if (!isMainLauncherActivity(act)) {
                        return;
                    }
                    launcherResumed = true;
                    launcherActivityRef = new WeakReference<>(act);
                    registerUnlockReceiverOnce(act);
                    maybeRunCleanUnlockBounce(act);
                }
            });
            hooked++;
        } catch (Throwable ignored) {
        }

        try {
            XposedBridge.hookAllMethods(Activity.class, "onPause", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (!(param.thisObject instanceof Activity)) {
                        return;
                    }
                    Activity act = (Activity) param.thisObject;
                    if (!isMainLauncherActivity(act)) {
                        return;
                    }
                    launcherResumed = false;
                    // Guarantee ZERO stuck/unsynced View transforms whenever leaving Home Screen
                    choreographer.cancelAllActive();
                }
            });
            hooked++;
        } catch (Throwable ignored) {
        }
        return hooked;
    }

    private static boolean isMainLauncherActivity(Activity act) {
        if (act == null) {
            return false;
        }
        String name = act.getClass().getName().toLowerCase(Locale.ROOT);
        return name.contains("launcher") && !name.contains("setting") && !name.contains("preference");
    }

    private void registerUnlockReceiverOnce(Activity act) {
        if (!receiverRegistered.compareAndSet(false, true)) {
            return;
        }
        try {
            Context appCtx = act.getApplicationContext() != null ? act.getApplicationContext() : act;
            IntentFilter filter = new IntentFilter();
            filter.addAction(Intent.ACTION_SCREEN_OFF);
            filter.addAction(Intent.ACTION_USER_PRESENT);
            BroadcastReceiver receiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    if (intent == null || intent.getAction() == null) {
                        return;
                    }
                    String action = intent.getAction();
                    if (Intent.ACTION_SCREEN_OFF.equals(action)) {
                        mainHandler.removeCallbacks(disarmUnlockRunnable);
                        armedForLockscreenUnlock = true;
                        mainHandler.post(new Runnable() {
                            @Override
                            public void run() {
                                choreographer.cancelAllActive();
                            }
                        });
                    } else if (Intent.ACTION_USER_PRESENT.equals(action)) {
                        if (!armedForLockscreenUnlock) {
                            return;
                        }
                        mainHandler.removeCallbacks(disarmUnlockRunnable);
                        // Disarm quickly if user unlocked into another app instead of Home Screen
                        mainHandler.postDelayed(disarmUnlockRunnable, UNLOCK_ARM_EXPIRE_MS);
                        mainHandler.post(new Runnable() {
                            @Override
                            public void run() {
                                Activity cur = launcherActivityRef.get();
                                if (cur != null && !cur.isFinishing() && launcherResumed) {
                                    maybeRunCleanUnlockBounce(cur);
                                }
                            }
                        });
                    }
                }
            };
            if (Build.VERSION.SDK_INT >= 33) {
                appCtx.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED);
            } else {
                appCtx.registerReceiver(receiver, filter);
            }
        } catch (Throwable ignored) {
            receiverRegistered.set(false);
        }
    }

    private void maybeRunCleanUnlockBounce(Activity act) {
        if (!armedForLockscreenUnlock || bugGuard.isHookTripped(CIRCUIT_UNLOCK)
                || bugGuard.isAnimationDisabledByUser()) {
            return;
        }
        if (Looper.myLooper() != Looper.getMainLooper() || act == null) {
            return;
        }
        try {
            KeyguardManager km = (KeyguardManager) act.getSystemService(Context.KEYGUARD_SERVICE);
            if (km != null && km.isKeyguardLocked()) {
                return;
            }
            // Disarm immediately so it can NEVER double-fire or randomly spawn later
            armedForLockscreenUnlock = false;
            mainHandler.removeCallbacks(disarmUnlockRunnable);

            MotionProfileSpec spec = specHub.getActiveSpec();
            if (spec == null || !spec.unlockBounceEnabled) {
                return;
            }
            long now = SystemClock.uptimeMillis();
            if ((now - unlockTriggeredUptimeMs) < UNLOCK_DEBOUNCE_MS) {
                return;
            }
            View root = getDecorView(act);
            if (root == null || root.getWidth() <= 0 || root.getHeight() <= 0) {
                return;
            }
            View recents = findViewByClassHint(root, "recentsview", true);
            if (recents != null && recents.getVisibility() == View.VISIBLE && recents.getAlpha() > 0.1f) {
                return;
            }
            unlockTriggeredUptimeMs = now;
            runCleanBouncyUnlock(root, spec);
        } catch (Throwable ignored) {
            bugGuard.recordHookFault(CIRCUIT_UNLOCK);
        }
    }

    /**
     * Synchronized, zero-pop bouncy Lock Screen -> Home Screen settle:
     * - NEVER changes alpha (prevents sudden vanish/re-spawn pop).
     * - NEVER touches Workspace container scale (prevents shrunk layout vs Hotseat desync).
     * - Gently expands visible CellLayout items radially & lifts Hotseat dock together
     *   using elastic underdamped CoreSpringSolver (zeta=0.58) that settles cleanly to rest.
     */
    private void runCleanBouncyUnlock(View root, MotionProfileSpec spec) {
        int screenW = root.getWidth();
        int screenH = root.getHeight();
        float centerX = screenW * 0.5f;
        float centerY = screenH * 0.45f;
        float maxRadius = (float) Math.hypot(centerX, centerY);
        if (maxRadius < 1.0f) {
            return;
        }
        float density = root.getResources() != null
                ? root.getResources().getDisplayMetrics().density : 2.75f;
        float spreadPx = spec.unlockRadialSpreadDp * density;
        float damp = spec.unlockDamping;
        float resp = spec.unlockResponseSec;

        ArrayList<View> icons = new ArrayList<>(MAX_UNLOCK_ICONS);
        int[] loc = new int[2];
        collectVisibleHomeItems(root, screenW, screenH, loc, icons);

        for (int i = 0; i < icons.size(); i++) {
            View item = icons.get(i);
            item.getLocationOnScreen(loc);
            float ix = loc[0] + item.getWidth() * 0.5f;
            float iy = loc[1] + item.getHeight() * 0.5f;
            float dx = ix - centerX;
            float dy = iy - centerY;
            float dist = (float) Math.hypot(dx, dy);
            float normDist = Math.min(1.0f, dist / maxRadius);
            float dirX = dist > 1.0f ? (dx / dist) : 0.0f;
            float dirY = dist > 1.0f ? (dy / dist) : 0.0f;

            float startTx = dirX * spreadPx * (0.30f + 0.70f * normDist);
            float startTy = dirY * spreadPx * (0.30f + 0.70f * normDist) + (12.0f * density);
            float startScale = 1.06f + (spec.unlockStartScale - 1.06f) * normDist;
            float delaySec = normDist * spec.unlockStaggerMaxSec;

            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_TRANSLATION_X,
                    startTx, 0.0f, -startTx * 2.4f, damp, resp, delaySec);
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_TRANSLATION_Y,
                    startTy, 0.0f, -startTy * 2.4f, damp, resp, delaySec);
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_SCALE_XY,
                    startScale, 1.0f, -(startScale - 1.0f) * 3.0f, damp, resp, delaySec);
        }

        View hotseat = findViewByClassHint(root, "hotseat", true);
        if (hotseat != null && hotseat.getVisibility() == View.VISIBLE) {
            float dockDropPx = 38.0f * density;
            float dockDamp = Math.max(0.55f, damp - 0.02f);
            choreographer.springTo(hotseat, CoreSurfaceChoreographer.PROP_TRANSLATION_Y,
                    dockDropPx, 0.0f, -dockDropPx * 2.5f, dockDamp, resp * 1.02f);
            choreographer.springTo(hotseat, CoreSurfaceChoreographer.PROP_SCALE_XY,
                    0.92f, 1.0f, 0.45f, dockDamp, resp * 1.02f);
        }

        if (!icons.isEmpty() || hotseat != null) {
            telemetry.incCurvesApplied();
        }
    }

    // -------------------------------------------------------------------------
    // 2. Native RectFSpringAnim App Open / Close Physics Calibration
    // -------------------------------------------------------------------------

    private int installRectFSpringHooks(ClassLoader cl) {
        int hooked = 0;
        for (String clsName : RECTF_CLASSES) {
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
                if (Modifier.isAbstract(m.getModifiers()) || Modifier.isNative(m.getModifiers())) {
                    continue;
                }
                String name = m.getName();
                Class<?>[] params = m.getParameterTypes();
                if ("start".equals(name) || "startInGestureThread".equals(name)
                        || "updateEndRectF".equals(name) || "startDirectly".equals(name)) {
                    if (hookRectFStart(m)) {
                        hooked++;
                    }
                } else if ("setStartVelocity".equals(name) && params.length == 2
                        && params[0] == float.class && params[1] == float.class) {
                    if (hookRectFVelocity(m)) {
                        hooked++;
                    }
                }
            }
        }
        return hooked;
    }

    private boolean hookRectFStart(Method method) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped(CIRCUIT_RECTF) || bugGuard.isAnimationDisabledByUser()) {
                        return;
                    }
                    try {
                        MotionProfileSpec spec = specHub.getActiveSpec();
                        if (spec == null || param.thisObject == null) {
                            return;
                        }
                        if (tuneRectFSpringAnim(param.thisObject, spec)) {
                            telemetry.incSpringsTuned();
                        }
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault(CIRCUIT_RECTF);
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private boolean hookRectFVelocity(Method method) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped(CIRCUIT_RECTF) || bugGuard.isAnimationDisabledByUser()) {
                        return;
                    }
                    try {
                        MotionProfileSpec spec = specHub.getActiveSpec();
                        if (spec == null || param.args == null || param.args.length < 2) {
                            return;
                        }
                        float vx = (Float) param.args[0];
                        float vy = (Float) param.args[1];
                        param.args[0] = vx * spec.appVelocityScale;
                        param.args[1] = vy * spec.appVelocityScale;
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault(CIRCUIT_RECTF);
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private boolean tuneRectFSpringAnim(Object rectAnim, MotionProfileSpec spec) {
        CachedRectFFields cached = getOrScanRectFFields(rectAnim.getClass());
        boolean tuned = false;
        float posStiff = MotionProfileSpec.responseToStiffness(spec.appPosResponseSec);
        float scaleStiff = MotionProfileSpec.responseToStiffness(spec.appScaleResponseSec);

        specHub.beginInternalSpringWrite();
        try {
            for (Field f : cached.posSpringFields) {
                if (applyToSpringObject(rectAnim, f, spec.appPosDamping, posStiff)) {
                    tuned = true;
                }
            }
            for (Field f : cached.scaleSpringFields) {
                if (applyToSpringObject(rectAnim, f, spec.appScaleDamping, scaleStiff)) {
                    tuned = true;
                }
            }
        } finally {
            specHub.endInternalSpringWrite();
        }
        return tuned;
    }

    private CachedRectFFields getOrScanRectFFields(Class<?> clazz) {
        CachedRectFFields existing = fieldCache.get(clazz);
        if (existing != null) {
            return existing;
        }
        ArrayList<Field> pos = new ArrayList<>();
        ArrayList<Field> scale = new ArrayList<>();
        Class<?> cur = clazz;
        while (cur != null && cur != Object.class) {
            try {
                for (Field f : cur.getDeclaredFields()) {
                    if (Modifier.isStatic(f.getModifiers())) {
                        continue;
                    }
                    String typeName = f.getType().getName().toLowerCase(Locale.ROOT);
                    if (!typeName.contains("spring")) {
                        continue;
                    }
                    String fname = f.getName().toLowerCase(Locale.ROOT);
                    if (fname.contains("alpha") || fname.contains("radius") || fname.contains("blur")) {
                        continue;
                    }
                    f.setAccessible(true);
                    if (fname.contains("width") || fname.contains("ratio") || fname.contains("scale")) {
                        scale.add(f);
                    } else {
                        pos.add(f);
                    }
                }
            } catch (Throwable ignored) {
            }
            cur = cur.getSuperclass();
        }
        CachedRectFFields result = new CachedRectFFields(
                pos.toArray(new Field[0]),
                scale.toArray(new Field[0]));
        fieldCache.put(clazz, result);
        return result;
    }

    private boolean applyToSpringObject(Object owner, Field f, float damping, float stiffness) {
        try {
            Object obj = f.get(owner);
            if (obj == null) {
                return false;
            }
            Object springForce = resolveSpringForce(obj);
            if (springForce == null) {
                return false;
            }
            Class<?> sfClass = springForce.getClass();
            Method mDamp = getCachedFloatMethod(sfClass, "setDampingRatio", dampSetterCache);
            Method mStiff = getCachedFloatMethod(sfClass, "setStiffness", stiffSetterCache);
            if (mDamp != null && mStiff != null) {
                mDamp.invoke(springForce, damping);
                mStiff.invoke(springForce, stiffness);
                return true;
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private Object resolveSpringForce(Object springHolder) {
        Class<?> cls = springHolder.getClass();
        String name = cls.getName().toLowerCase(Locale.ROOT);
        if (name.contains("springforce")) {
            return springHolder;
        }
        Method getter = springGetterCache.get(cls);
        if (getter == null) {
            try {
                getter = cls.getMethod("getSpring");
                springGetterCache.put(cls, getter);
            } catch (Throwable ignored) {
                return null;
            }
        }
        try {
            return getter.invoke(springHolder);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static Method getCachedFloatMethod(Class<?> cls, String name,
                                               ConcurrentHashMap<Class<?>, Method> cache) {
        Method m = cache.get(cls);
        if (m != null) {
            return m;
        }
        try {
            m = cls.getMethod(name, float.class);
            cache.put(cls, m);
            return m;
        } catch (Throwable ignored) {
            return null;
        }
    }

    // -------------------------------------------------------------------------
    // 3. Interruptible Folder Open/Close Choreography
    // -------------------------------------------------------------------------

    private int installFolderChoreographyHooks(ClassLoader cl) {
        int hooked = 0;
        for (String clsName : FOLDER_CLASSES) {
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
                if (Modifier.isAbstract(m.getModifiers()) || Modifier.isNative(m.getModifiers())) {
                    continue;
                }
                String name = m.getName();
                if ("onOpen".equals(name) || "animateOpen".equals(name) || "open".equals(name)) {
                    if (hookFolderLifecycle(m, true)) {
                        hooked++;
                    }
                } else if ("onClose".equals(name) || "close".equals(name)) {
                    if (hookFolderLifecycle(m, false)) {
                        hooked++;
                    }
                }
            }
        }
        return hooked;
    }

    private boolean hookFolderLifecycle(Method method, final boolean isOpen) {
        try {
            XposedBridge.hookMethod(method, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (bugGuard.isHookTripped(CIRCUIT_FOLDER) || bugGuard.isAnimationDisabledByUser()) {
                        return;
                    }
                    if (Looper.myLooper() != Looper.getMainLooper() || !(param.thisObject instanceof View)) {
                        return;
                    }
                    try {
                        View v = (View) param.thisObject;
                        if (!isOpen) {
                            choreographer.cancelAndReset(v, CoreSurfaceChoreographer.PROP_TRANSLATION_Y);
                            return;
                        }
                        MotionProfileSpec spec = specHub.getActiveSpec();
                        if (spec == null || !v.isAttachedToWindow()) {
                            return;
                        }
                        float density = v.getResources() != null
                                ? v.getResources().getDisplayMetrics().density : 2.75f;
                        float liftPx = spec.surfaceLiftDp * density;
                        float initialVel = -liftPx * spec.surfaceImpulseVel;
                        choreographer.springTo(
                                v,
                                CoreSurfaceChoreographer.PROP_TRANSLATION_Y,
                                liftPx,
                                0.0f,
                                initialVel,
                                spec.surfaceDamping,
                                spec.surfaceResponseSec);
                    } catch (Throwable ignored) {
                        bugGuard.recordHookFault(CIRCUIT_FOLDER);
                    }
                }
            });
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    // -------------------------------------------------------------------------
    // View Hierarchy Helpers
    // -------------------------------------------------------------------------

    private static View getDecorView(Activity act) {
        if (act == null) {
            return null;
        }
        Window w = act.getWindow();
        return w != null ? w.getDecorView() : null;
    }

    private static View findViewByClassHint(View node, String hintLower, boolean visibleOnly) {
        if (node == null) {
            return null;
        }
        if (visibleOnly && node.getVisibility() != View.VISIBLE) {
            return null;
        }
        String cls = node.getClass().getSimpleName().toLowerCase(Locale.ROOT);
        if (cls.contains(hintLower)) {
            return node;
        }
        if (node instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) node;
            int count = vg.getChildCount();
            for (int i = 0; i < count; i++) {
                View hit = findViewByClassHint(vg.getChildAt(i), hintLower, visibleOnly);
                if (hit != null) {
                    return hit;
                }
            }
        }
        return null;
    }

    private static void collectVisibleHomeItems(View node, int screenW, int screenH,
                                                int[] loc, ArrayList<View> out) {
        if (node == null || out.size() >= MAX_UNLOCK_ICONS || node.getVisibility() != View.VISIBLE) {
            return;
        }
        String cls = node.getClass().getSimpleName().toLowerCase(Locale.ROOT);
        if ((cls.contains("celllayout") || cls.contains("shortcutscreen")) && node instanceof ViewGroup) {
            node.getLocationOnScreen(loc);
            if (loc[0] >= -screenW / 4 && loc[0] <= screenW / 4 && node.getWidth() > screenW / 2) {
                ViewGroup cell = (ViewGroup) node;
                int count = cell.getChildCount();
                for (int i = 0; i < count && out.size() < MAX_UNLOCK_ICONS; i++) {
                    View child = cell.getChildAt(i);
                    if (child == null || child.getVisibility() != View.VISIBLE
                            || child.getWidth() <= 0 || child.getHeight() <= 0) {
                        continue;
                    }
                    child.getLocationOnScreen(loc);
                    int cx = loc[0] + child.getWidth() / 2;
                    int cy = loc[1] + child.getHeight() / 2;
                    if (cx >= 0 && cx <= screenW && cy >= 0 && cy <= screenH) {
                        out.add(child);
                    }
                }
                return;
            }
        }
        if (node instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) node;
            int count = vg.getChildCount();
            for (int i = 0; i < count && out.size() < MAX_UNLOCK_ICONS; i++) {
                collectVisibleHomeItems(vg.getChildAt(i), screenW, screenH, loc, out);
            }
        }
    }

    private static Class<?> safeFindClass(String className, ClassLoader cl) {
        try {
            return XposedHelpers.findClassIfExists(className, cl);
        } catch (Throwable ignored) {
            return null;
        }
    }
}
