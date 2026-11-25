package org.mystivara.coresurface.engine;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.RectF;
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
 * CoreSurface Launcher Physics & iOS 27 3D Choreography Engine (com.miui.home / POCO Launcher).
 *
 * 1. Universal Activity Lifecycle Binding (100% obfuscation- & inheritance-proof):
 *    - Hooks android.app.Activity.onResume / onPause / onWindowFocusChanged directly inside the
 *      Launcher process so we ALWAYS capture the active Launcher Activity, root content View,
 *      and Workspace regardless of HyperOS 2/3/4 class hierarchy changes.
 * 2. iOS 27 3D Perspective App Open / App Close (`ios` profile):
 *    - Primary: hooks RectFSpringAnim (`start*`) + scans all RectF fields (by name or position).
 *    - Guaranteed fallback: hooks Launcher onPause (App Open) & onResume (Return Home) so 3D
 *      perspective depth recession (scale 1.0 <-> 0.89 + directional rotationX/rotationY) ALWAYS
 *      fires cleanly even if Xiaomi renames RectFSpringAnim fields.
 * 3. iOS 27 Bouncy Lock Screen -> Home Screen Radial Fly-In (`ios` profile):
 *    - Event-driven via ACTION_SCREEN_OFF + ACTION_USER_PRESENT + Keyguard unlock edge (0% polling).
 *    - Animates Workspace + every visible CellLayout icon/widget + Hotseat dock with genuine
 *      underdamped bouncy CoreSpringSolver (zeta=0.54) and radial wave stagger.
 * 4. Interruptible Folder Open/Close Choreography (`CoreSurfaceChoreographer`).
 */
public final class LauncherChoreographyHook {
    private static final String CIRCUIT_RECTF = "LauncherRectF";
    private static final String CIRCUIT_FOLDER = "LauncherFolder";
    private static final String CIRCUIT_IOS27 = "LauncherIos27";

    private static final long UNLOCK_WINDOW_MS = 1800L;
    private static final long UNLOCK_DEBOUNCE_MS = 900L;
    private static final long PERSPECTIVE_DEBOUNCE_MS = 220L;
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
        final Field startRectField;
        final Field endRectField;

        CachedRectFFields(Field[] pos, Field[] scale, Field startRect, Field endRect) {
            this.posSpringFields = pos;
            this.scaleSpringFields = scale;
            this.startRectField = startRect;
            this.endRectField = endRect;
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
    private final AtomicBoolean logged3dOnce = new AtomicBoolean(false);
    private final AtomicBoolean loggedUnlockOnce = new AtomicBoolean(false);

    private volatile WeakReference<Activity> launcherActivityRef = new WeakReference<>(null);
    private volatile WeakReference<View> workspaceViewRef = new WeakReference<>(null);
    private volatile boolean launcherResumed = false;
    private volatile boolean leftLauncherForApp = false;
    private volatile boolean pendingUnlockFromScreenOff = false;
    private volatile long lastUserPresentUptimeMs = 0L;
    private volatile long lastUnlockAnimUptimeMs = 0L;
    private volatile long lastPerspectiveAnimUptimeMs = 0L;
    private volatile boolean workspaceRecededForAppOpen = false;
    private volatile float lastOpenTiltX = 0.0f;
    private volatile float lastOpenTiltY = 0.0f;

    private final Runnable workspaceRestoreRunnable = new Runnable() {
        @Override
        public void run() {
            View ws = getPerspectiveTargetView();
            if (ws != null && workspaceRecededForAppOpen) {
                workspaceRecededForAppOpen = false;
                choreographer.cancelAllForView(ws);
            }
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
    // 1. Universal Activity Lifecycle & Zero-Polling Lock->Home Unlock Observer
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
                    onLauncherActive(act);

                    // Priority 1: Lock Screen -> Home Screen bouncy fly-in
                    if (maybeTriggerIos27UnlockBounce(act)) {
                        leftLauncherForApp = false;
                        return;
                    }

                    // Priority 2: Guaranteed 3D Perspective emergence when returning from an app
                    if (leftLauncherForApp) {
                        leftLauncherForApp = false;
                        MotionProfileSpec spec = specHub.getActiveSpec();
                        long now = SystemClock.uptimeMillis();
                        if (spec != null && spec.ios3dPerspectiveEnabled
                                && (now - lastPerspectiveAnimUptimeMs) > PERSPECTIVE_DEBOUNCE_MS) {
                            lastPerspectiveAnimUptimeMs = now;
                            applyWorkspace3dPerspective(false, 0.5f, 0.5f, true, spec);
                        }
                    }
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
                    if (isKeyguardLockedSafe(act)) {
                        pendingUnlockFromScreenOff = true;
                        leftLauncherForApp = false;
                        return;
                    }
                    leftLauncherForApp = true;
                    MotionProfileSpec spec = specHub.getActiveSpec();
                    long now = SystemClock.uptimeMillis();
                    if (spec != null && spec.ios3dPerspectiveEnabled
                            && (now - lastPerspectiveAnimUptimeMs) > PERSPECTIVE_DEBOUNCE_MS) {
                        lastPerspectiveAnimUptimeMs = now;
                        applyWorkspace3dPerspective(true, 0.5f, 0.65f, true, spec);
                    }
                }
            });
            hooked++;
        } catch (Throwable ignored) {
        }

        try {
            XposedBridge.hookAllMethods(Activity.class, "onWindowFocusChanged", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!(param.thisObject instanceof Activity)
                            || param.args == null || param.args.length < 1
                            || !Boolean.TRUE.equals(param.args[0])) {
                        return;
                    }
                    Activity act = (Activity) param.thisObject;
                    if (!isMainLauncherActivity(act)) {
                        return;
                    }
                    onLauncherActive(act);
                    maybeTriggerIos27UnlockBounce(act);
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

    private void onLauncherActive(Activity act) {
        launcherActivityRef = new WeakReference<>(act);
        registerUnlockReceiverOnce(act);
        View ws = workspaceViewRef.get();
        if (ws == null || !ws.isAttachedToWindow()) {
            View found = findViewByClassHint(getDecorView(act), "workspace", true);
            if (found != null) {
                workspaceViewRef = new WeakReference<>(found);
            }
        }
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
                        pendingUnlockFromScreenOff = true;
                        workspaceRecededForAppOpen = false;
                        leftLauncherForApp = false;
                    } else if (Intent.ACTION_USER_PRESENT.equals(action)) {
                        lastUserPresentUptimeMs = SystemClock.uptimeMillis();
                        pendingUnlockFromScreenOff = true;
                        mainHandler.post(new Runnable() {
                            @Override
                            public void run() {
                                Activity cur = launcherActivityRef.get();
                                if (cur != null && !cur.isFinishing()) {
                                    maybeTriggerIos27UnlockBounce(cur);
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

    private boolean maybeTriggerIos27UnlockBounce(Activity act) {
        if (bugGuard.isHookTripped(CIRCUIT_IOS27) || bugGuard.isAnimationDisabledByUser()) {
            return false;
        }
        if (Looper.myLooper() != Looper.getMainLooper() || act == null) {
            return false;
        }
        MotionProfileSpec spec = specHub.getActiveSpec();
        if (spec == null || !spec.unlockBounceEnabled) {
            return false;
        }
        long now = SystemClock.uptimeMillis();
        boolean recentUserPresent = lastUserPresentUptimeMs > 0L
                && (now - lastUserPresentUptimeMs) <= UNLOCK_WINDOW_MS;
        if (!pendingUnlockFromScreenOff && !recentUserPresent) {
            return false;
        }
        if ((now - lastUnlockAnimUptimeMs) < UNLOCK_DEBOUNCE_MS) {
            return false;
        }
        try {
            if (isKeyguardLockedSafe(act)) {
                return false;
            }
            if (!launcherResumed && !act.hasWindowFocus()) {
                return false;
            }
            View root = getDecorView(act);
            if (root == null || root.getWidth() <= 0 || root.getHeight() <= 0) {
                return false;
            }
            View recents = findViewByClassHint(root, "recentsview", true);
            if (recents != null && recents.getVisibility() == View.VISIBLE && recents.getAlpha() > 0.1f) {
                return false;
            }
            pendingUnlockFromScreenOff = false;
            lastUnlockAnimUptimeMs = now;
            runIos27UnlockBounce(root, spec);
            return true;
        } catch (Throwable ignored) {
            bugGuard.recordHookFault(CIRCUIT_IOS27);
            return false;
        }
    }

    /**
     * Authentic iOS 27 Lock Screen -> Home Screen bouncy radial fly-in:
     * - Workspace container emerges from 3D depth with bouncy scale + tilt settle.
     * - Active CellLayout icons/widgets fly inward radially with stagger and zeta=0.54 bounce.
     * - Hotseat dock leaps upward from below with matching bouncy spring.
     */
    private void runIos27UnlockBounce(View root, MotionProfileSpec spec) {
        int screenW = root.getWidth();
        int screenH = root.getHeight();
        float centerX = screenW * 0.5f;
        float centerY = screenH * 0.44f;
        float maxRadius = (float) Math.hypot(centerX, centerY);
        if (maxRadius < 1.0f) {
            return;
        }
        float density = root.getResources() != null
                ? root.getResources().getDisplayMetrics().density : 2.75f;
        float spreadPx = spec.unlockRadialSpreadDp * density;
        float damp = spec.unlockDamping;
        float resp = spec.unlockResponseSec;
        int animatedCount = 0;

        // 1. Workspace container itself gets a clean 3D depth bounce (guarantees visible bounce even on sparse pages)
        View ws = getPerspectiveTargetView();
        if (ws != null && ws.isAttachedToWindow()) {
            ws.setPivotX(ws.getWidth() * 0.5f);
            ws.setPivotY(ws.getHeight() * 0.5f);
            choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_SCALE_XY,
                    1.15f, 1.0f, -0.55f, Math.min(0.60f, damp + 0.04f), resp);
            choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_ROTATION_X,
                    8.5f, 0.0f, -18.0f, Math.min(0.68f, damp + 0.10f), resp);
            animatedCount++;
        }

        // 2. Active CellLayout icons & widgets fly in radially with elastic bounce
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

            float startTx = dirX * spreadPx * (0.35f + 0.65f * normDist);
            float startTy = dirY * spreadPx * (0.35f + 0.65f * normDist) + (16.0f * density);
            float startScale = 1.14f + (spec.unlockStartScale - 1.14f) * normDist;
            float startRotX = spec.unlockTiltXDeg * (0.55f + 0.45f * normDist);
            float delaySec = normDist * spec.unlockStaggerMaxSec;

            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_TRANSLATION_X,
                    startTx, 0.0f, -startTx * 2.6f, damp, resp, delaySec);
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_TRANSLATION_Y,
                    startTy, 0.0f, -startTy * 2.6f, damp, resp, delaySec);
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_SCALE_XY,
                    startScale, 1.0f, -(startScale - 1.0f) * 3.4f, damp, resp, delaySec);
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_ROTATION_X,
                    startRotX, 0.0f, -startRotX * 2.4f, Math.min(0.70f, damp + 0.08f), resp, delaySec);
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_ALPHA,
                    0.15f, 1.0f, 3.2f, 0.96f, resp * 0.52f, delaySec);
            animatedCount++;
        }

        // 3. Hotseat dock rises energetically from below with matching bounce
        View hotseat = findViewByClassHint(root, "hotseat", true);
        if (hotseat != null && hotseat.getVisibility() == View.VISIBLE) {
            float dockDropPx = 64.0f * density;
            float dockDamp = Math.max(0.52f, damp - 0.02f);
            choreographer.springTo(hotseat, CoreSurfaceChoreographer.PROP_TRANSLATION_Y,
                    dockDropPx, 0.0f, -dockDropPx * 2.8f, dockDamp, resp * 1.04f);
            choreographer.springTo(hotseat, CoreSurfaceChoreographer.PROP_SCALE_XY,
                    0.86f, 1.0f, 0.65f, dockDamp, resp * 1.04f);
            choreographer.springTo(hotseat, CoreSurfaceChoreographer.PROP_ROTATION_X,
                    11.0f, 0.0f, -22.0f, Math.min(0.72f, dockDamp + 0.08f), resp);
            animatedCount++;
        }

        if (animatedCount > 0) {
            telemetry.incCurvesApplied();
            if (loggedUnlockOnce.compareAndSet(false, true)) {
                XposedBridge.log("CoreSurfaceEngine: iOS 27 Bouncy Lock->Home fired (items=" + animatedCount + ")");
            }
        }
    }

    // -------------------------------------------------------------------------
    // 2. App Open / Close RectFSpringAnim + iOS 27 3D Perspective Workspace Depth
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
                        if (spec.ios3dPerspectiveEnabled) {
                            scheduleAppTransition3dPerspective(param.thisObject, spec);
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

    private void scheduleAppTransition3dPerspective(Object rectAnim, final MotionProfileSpec spec) {
        CachedRectFFields cached = getOrScanRectFFields(rectAnim.getClass());
        RectF startRect = readRectField(rectAnim, cached.startRectField);
        RectF endRect = readRectField(rectAnim, cached.endRectField);
        final boolean isOpening;
        final float coordX;
        final float coordY;
        final boolean normalizedCoords;

        if (startRect != null && endRect != null && Math.abs(endRect.width() - startRect.width()) > 20.0f) {
            isOpening = endRect.width() > startRect.width();
            RectF iconRect = isOpening ? startRect : endRect;
            coordX = iconRect.centerX();
            coordY = iconRect.centerY();
            normalizedCoords = false;
        } else {
            // Fallback when RectF fields are obfuscated: infer direction from launcherResumed state
            isOpening = launcherResumed;
            coordX = 0.5f;
            coordY = 0.65f;
            normalizedCoords = true;
        }

        lastPerspectiveAnimUptimeMs = SystemClock.uptimeMillis();
        Runnable task = new Runnable() {
            @Override
            public void run() {
                applyWorkspace3dPerspective(isOpening, coordX, coordY, normalizedCoords, spec);
            }
        };
        if (Looper.myLooper() == Looper.getMainLooper()) {
            task.run();
        } else {
            mainHandler.post(task);
        }
    }

    private void applyWorkspace3dPerspective(boolean isOpening, float x, float y,
                                             boolean isNormalized, MotionProfileSpec spec) {
        if (bugGuard.isHookTripped(CIRCUIT_IOS27)) {
            return;
        }
        try {
            View ws = getPerspectiveTargetView();
            if (ws == null || !ws.isAttachedToWindow() || ws.getWidth() <= 0 || ws.getHeight() <= 0) {
                return;
            }
            float nx = isNormalized
                    ? clamp(x * 2.0f - 1.0f, -1.0f, 1.0f)
                    : clamp((x / (float) ws.getWidth()) * 2.0f - 1.0f, -1.0f, 1.0f);
            float ny = isNormalized
                    ? clamp(y * 2.0f - 1.0f, -1.0f, 1.0f)
                    : clamp((y / (float) ws.getHeight()) * 2.0f - 1.0f, -1.0f, 1.0f);

            ws.setPivotX(ws.getWidth() * 0.5f);
            ws.setPivotY(ws.getHeight() * 0.5f);

            // Guarantee a clearly felt 3D perspective angle even for center icons
            float baseTiltX = (Math.abs(ny) < 0.25f) ? 0.55f : -ny;
            float tiltX = baseTiltX * spec.perspectiveMaxTiltXDeg;
            float tiltY = nx * spec.perspectiveMaxTiltYDeg;
            float depthScale = spec.perspectiveDepthScale;

            mainHandler.removeCallbacks(workspaceRestoreRunnable);
            if (isOpening) {
                workspaceRecededForAppOpen = true;
                lastOpenTiltX = tiltX;
                lastOpenTiltY = tiltY;
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_SCALE_XY,
                        ws.getScaleX(), depthScale, -0.45f, 0.88f, spec.perspectiveResponseSec * 0.82f);
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_ROTATION_X,
                        ws.getRotationX(), tiltX, tiltX * 2.6f, 0.88f, spec.perspectiveResponseSec * 0.82f);
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_ROTATION_Y,
                        ws.getRotationY(), tiltY, tiltY * 2.6f, 0.88f, spec.perspectiveResponseSec * 0.82f);
                mainHandler.postDelayed(workspaceRestoreRunnable, 480L);
            } else {
                float startScale = workspaceRecededForAppOpen ? ws.getScaleX() : depthScale;
                float startRotX = workspaceRecededForAppOpen ? ws.getRotationX()
                        : (Math.abs(lastOpenTiltX) > 0.3f ? lastOpenTiltX : tiltX);
                float startRotY = workspaceRecededForAppOpen ? ws.getRotationY()
                        : (Math.abs(lastOpenTiltY) > 0.3f ? lastOpenTiltY : tiltY);
                workspaceRecededForAppOpen = false;
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_SCALE_XY,
                        startScale, 1.0f, 0.55f, spec.perspectiveDamping, spec.perspectiveResponseSec);
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_ROTATION_X,
                        startRotX, 0.0f, -startRotX * 2.8f, spec.perspectiveDamping, spec.perspectiveResponseSec);
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_ROTATION_Y,
                        startRotY, 0.0f, -startRotY * 2.8f, spec.perspectiveDamping, spec.perspectiveResponseSec);
            }
            telemetry.incCurvesApplied();
            if (logged3dOnce.compareAndSet(false, true)) {
                XposedBridge.log("CoreSurfaceEngine: iOS 27 3D Perspective fired (open=" + isOpening
                        + ", target=" + ws.getClass().getSimpleName() + ")");
            }
        } catch (Throwable ignored) {
            bugGuard.recordHookFault(CIRCUIT_IOS27);
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
        ArrayList<Field> anyRects = new ArrayList<>();
        Field startRect = null;
        Field endRect = null;
        Class<?> cur = clazz;
        while (cur != null && cur != Object.class) {
            try {
                for (Field f : cur.getDeclaredFields()) {
                    if (Modifier.isStatic(f.getModifiers())) {
                        continue;
                    }
                    Class<?> fType = f.getType();
                    String fname = f.getName().toLowerCase(Locale.ROOT);
                    if (RectF.class.isAssignableFrom(fType)) {
                        f.setAccessible(true);
                        anyRects.add(f);
                        if (startRect == null && fname.contains("start")) {
                            startRect = f;
                        } else if (endRect == null && (fname.contains("end") || fname.contains("target"))) {
                            endRect = f;
                        }
                        continue;
                    }
                    String typeName = fType.getName().toLowerCase(Locale.ROOT);
                    if (!typeName.contains("spring")) {
                        continue;
                    }
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
        // Positional fallback when RectF fields are obfuscated
        if ((startRect == null || endRect == null) && anyRects.size() >= 2) {
            startRect = anyRects.get(0);
            endRect = anyRects.get(1);
        }
        CachedRectFFields result = new CachedRectFFields(
                pos.toArray(new Field[0]),
                scale.toArray(new Field[0]),
                startRect,
                endRect);
        fieldCache.put(clazz, result);
        return result;
    }

    private static RectF readRectField(Object owner, Field f) {
        if (owner == null || f == null) {
            return null;
        }
        try {
            Object val = f.get(owner);
            return (val instanceof RectF) ? (RectF) val : null;
        } catch (Throwable ignored) {
            return null;
        }
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
    // View Hierarchy Helpers (Zero-Allocation Steady State, Run Only on Events)
    // -------------------------------------------------------------------------

    private View getPerspectiveTargetView() {
        View ws = workspaceViewRef.get();
        if (ws != null && ws.isAttachedToWindow()) {
            return ws;
        }
        Activity act = launcherActivityRef.get();
        if (act == null) {
            return null;
        }
        View decor = getDecorView(act);
        ws = findViewByClassHint(decor, "workspace", true);
        if (ws == null) {
            ws = findViewByClassHint(decor, "draglayer", true);
        }
        if (ws == null) {
            ws = act.findViewById(android.R.id.content);
        }
        if (ws != null) {
            workspaceViewRef = new WeakReference<>(ws);
        }
        return ws;
    }

    private static boolean isKeyguardLockedSafe(Activity act) {
        try {
            KeyguardManager km = (KeyguardManager) act.getSystemService(Context.KEYGUARD_SERVICE);
            return km != null && km.isKeyguardLocked();
        } catch (Throwable ignored) {
            return false;
        }
    }

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

    private static float clamp(float v, float min, float max) {
        return Math.max(min, Math.min(max, v));
    }
}
