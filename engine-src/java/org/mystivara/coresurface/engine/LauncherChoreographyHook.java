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
 * 1. App Open / App Close / Swipe-Up-to-Home (`RectFSpringAnim`):
 *    - Reflectively caches spatial spring & RectF fields once per class (zero per-frame reflection).
 *    - Configures X/Y/Width/Scale SpringForce damping & stiffness = (2*pi/T)^2 and scales
 *      finger-release velocity handoff while leaving Alpha & CornerRadius springs untouched.
 *    - In iOS 27 (`ios`) profile: drives genuine GPU 4x4 3D Perspective depth recession &
 *      directional tilt (cameraDistance + rotationX + rotationY + scaleXY) on the Home Screen
 *      Workspace during app open/close, with automatic identity settle safety.
 * 2. iOS 27 Bouncy Lock Screen -> Home Screen Radial Fly-In (`ios` profile):
 *    - Zero-polling event-driven detection via Keyguard/ACTION_USER_PRESENT + Launcher focus.
 *    - Drives visible Home Screen icons/widgets (CellLayout) and Hotseat dock from 3D radial
 *      depth with staggered wave timing and genuine underdamped bouncy CoreSpringSolver (zeta=0.65).
 * 3. Interruptible Folder Open/Close Choreography (`CoreSurfaceChoreographer`):
 *    - Drives a clean, zero-conflict `translationY` depth settle via CoreSpringSolver on VSync.
 */
public final class LauncherChoreographyHook {
    private static final String CIRCUIT_RECTF = "LauncherRectF";
    private static final String CIRCUIT_FOLDER = "LauncherFolder";
    private static final String CIRCUIT_IOS27 = "LauncherIos27";

    private static final long UNLOCK_WINDOW_MS = 1400L;
    private static final long UNLOCK_DEBOUNCE_MS = 900L;
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

    private static final String[] LAUNCHER_ACTIVITY_CLASSES = new String[] {
            "com.miui.home.launcher.Launcher",
            "com.mi.android.globallauncher.Launcher"
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
    private volatile WeakReference<Activity> launcherActivityRef = new WeakReference<>(null);
    private volatile WeakReference<View> workspaceViewRef = new WeakReference<>(null);
    private volatile boolean pendingUnlockFromScreenOff = false;
    private volatile long lastUserPresentUptimeMs = 0L;
    private volatile long lastUnlockAnimUptimeMs = 0L;
    private volatile boolean workspaceRecededForAppOpen = false;
    private volatile float lastOpenTiltX = 0.0f;
    private volatile float lastOpenTiltY = 0.0f;

    private final Runnable workspaceRestoreRunnable = new Runnable() {
        @Override
        public void run() {
            View ws = getWorkspaceView();
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
        hooked += installLauncherLifecycleHooks(cl);
        if (hooked > 0) {
            telemetry.addFolmeHooksBound(hooked);
            telemetry.recordHookBound("LauncherChoreography");
        }
        return hooked;
    }

    // -------------------------------------------------------------------------
    // 1. Launcher Activity Lifecycle & Zero-Polling Lock->Home Unlock Observer
    // -------------------------------------------------------------------------

    private int installLauncherLifecycleHooks(ClassLoader cl) {
        int hooked = 0;
        for (String clsName : LAUNCHER_ACTIVITY_CLASSES) {
            Class<?> clazz = safeFindClass(clsName, cl);
            if (clazz == null) {
                continue;
            }
            try {
                XposedBridge.hookAllMethods(clazz, "onResume", new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        if (param.thisObject instanceof Activity) {
                            Activity act = (Activity) param.thisObject;
                            onLauncherActive(act);
                        }
                    }
                });
                hooked++;
            } catch (Throwable ignored) {
            }
            try {
                XposedBridge.hookAllMethods(clazz, "onWindowFocusChanged", new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        if (param.thisObject instanceof Activity
                                && param.args != null && param.args.length >= 1
                                && Boolean.TRUE.equals(param.args[0])) {
                            Activity act = (Activity) param.thisObject;
                            onLauncherActive(act);
                            maybeTriggerIos27UnlockBounce(act);
                        }
                    }
                });
                hooked++;
            } catch (Throwable ignored) {
            }
        }
        return hooked;
    }

    private void onLauncherActive(Activity act) {
        launcherActivityRef = new WeakReference<>(act);
        registerUnlockReceiverOnce(act);
        // Refresh Workspace reference cheaply if null or detached
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

    private void maybeTriggerIos27UnlockBounce(Activity act) {
        if (bugGuard.isHookTripped(CIRCUIT_IOS27) || bugGuard.isAnimationDisabledByUser()) {
            return;
        }
        if (Looper.myLooper() != Looper.getMainLooper() || act == null) {
            return;
        }
        MotionProfileSpec spec = specHub.getActiveSpec();
        if (spec == null || !spec.unlockBounceEnabled) {
            return;
        }
        long now = SystemClock.uptimeMillis();
        if (!pendingUnlockFromScreenOff) {
            return;
        }
        if (lastUserPresentUptimeMs <= 0L || (now - lastUserPresentUptimeMs) > UNLOCK_WINDOW_MS) {
            return;
        }
        if ((now - lastUnlockAnimUptimeMs) < UNLOCK_DEBOUNCE_MS) {
            return;
        }
        try {
            KeyguardManager km = (KeyguardManager) act.getSystemService(Context.KEYGUARD_SERVICE);
            if (km != null && km.isKeyguardLocked()) {
                return;
            }
            if (!act.hasWindowFocus()) {
                return;
            }
            View root = getDecorView(act);
            if (root == null || root.getWidth() <= 0 || root.getHeight() <= 0) {
                return;
            }
            // Skip cleanly if Recents or an open Folder is covering the Home Screen
            View recents = findViewByClassHint(root, "recentsview", true);
            if (recents != null && recents.getVisibility() == View.VISIBLE && recents.getAlpha() > 0.1f) {
                return;
            }
            pendingUnlockFromScreenOff = false;
            lastUnlockAnimUptimeMs = now;
            runIos27UnlockBounce(root, spec);
        } catch (Throwable ignored) {
            bugGuard.recordHookFault(CIRCUIT_IOS27);
        }
    }

    /**
     * Authentic iOS 27 Lock Screen -> Home Screen bouncy radial fly-in:
     * - Active CellLayout icons/widgets fly inward from 3D radial depth with subtle center-out
     *   stagger and elastic underdamped bounce (zeta=0.65 -> ~6.8% clean overshoot).
     * - Hotseat dock rises energetically from below with matching bouncy spring settle.
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

        ArrayList<View> icons = new ArrayList<>(MAX_UNLOCK_ICONS);
        int[] loc = new int[2];
        collectVisibleHomeItems(root, screenW, screenH, loc, icons);

        float damp = spec.unlockDamping;
        float resp = spec.unlockResponseSec;
        int animatedCount = 0;

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
            float startTy = dirY * spreadPx * (0.35f + 0.65f * normDist) + (14.0f * density);
            float startScale = 1.12f + (spec.unlockStartScale - 1.12f) * normDist;
            float startRotX = spec.unlockTiltXDeg * (0.55f + 0.45f * normDist);
            float delaySec = normDist * spec.unlockStaggerMaxSec;

            // Energetic inward initial velocity makes the iOS 27 landing unmistakably bouncy
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_TRANSLATION_X,
                    startTx, 0.0f, -startTx * 2.4f, damp, resp, delaySec);
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_TRANSLATION_Y,
                    startTy, 0.0f, -startTy * 2.4f, damp, resp, delaySec);
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_SCALE_XY,
                    startScale, 1.0f, -(startScale - 1.0f) * 3.2f, damp, resp, delaySec);
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_ROTATION_X,
                    startRotX, 0.0f, -startRotX * 2.2f, Math.min(0.74f, damp + 0.06f), resp, delaySec);
            choreographer.springToDelayed(item, CoreSurfaceChoreographer.PROP_ALPHA,
                    0.18f, 1.0f, 3.0f, 0.96f, resp * 0.55f, delaySec);
            animatedCount++;
        }

        // Hotseat dock rises with a juicy bouncy spring from below
        View hotseat = findViewByClassHint(root, "hotseat", true);
        if (hotseat != null && hotseat.getVisibility() == View.VISIBLE) {
            float dockDropPx = 56.0f * density;
            float dockDamp = Math.max(0.54f, damp - 0.02f);
            choreographer.springTo(hotseat, CoreSurfaceChoreographer.PROP_TRANSLATION_Y,
                    dockDropPx, 0.0f, -dockDropPx * 2.6f, dockDamp, resp * 1.04f);
            choreographer.springTo(hotseat, CoreSurfaceChoreographer.PROP_SCALE_XY,
                    0.88f, 1.0f, 0.55f, dockDamp, resp * 1.04f);
            choreographer.springTo(hotseat, CoreSurfaceChoreographer.PROP_ROTATION_X,
                    9.5f, 0.0f, -18.0f, Math.min(0.75f, dockDamp + 0.06f), resp);
            animatedCount++;
        }

        if (animatedCount > 0) {
            telemetry.incCurvesApplied();
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
        if (startRect == null || endRect == null) {
            return;
        }
        final boolean isOpening = endRect.width() > startRect.width() * 1.15f;
        final boolean isClosing = startRect.width() > endRect.width() * 1.15f;
        if (!isOpening && !isClosing) {
            return;
        }
        final RectF iconRect = isOpening ? startRect : endRect;
        final float iconCx = iconRect.centerX();
        final float iconCy = iconRect.centerY();

        Runnable task = new Runnable() {
            @Override
            public void run() {
                applyWorkspace3dPerspective(isOpening, iconCx, iconCy, spec);
            }
        };
        if (Looper.myLooper() == Looper.getMainLooper()) {
            task.run();
        } else {
            mainHandler.post(task);
        }
    }

    private void applyWorkspace3dPerspective(boolean isOpening, float iconCx, float iconCy,
                                             MotionProfileSpec spec) {
        if (bugGuard.isHookTripped(CIRCUIT_IOS27)) {
            return;
        }
        try {
            View ws = getWorkspaceView();
            if (ws == null || !ws.isAttachedToWindow() || ws.getWidth() <= 0 || ws.getHeight() <= 0) {
                return;
            }
            float nx = clamp((iconCx / (float) ws.getWidth()) * 2.0f - 1.0f, -1.0f, 1.0f);
            float ny = clamp((iconCy / (float) ws.getHeight()) * 2.0f - 1.0f, -1.0f, 1.0f);

            // Pivot around the center of the Home Screen for clean symmetric 3D depth plane
            ws.setPivotX(ws.getWidth() * 0.5f);
            ws.setPivotY(ws.getHeight() * 0.5f);

            float tiltX = -ny * spec.perspectiveMaxTiltXDeg;
            float tiltY = nx * spec.perspectiveMaxTiltYDeg;
            float depthScale = spec.perspectiveDepthScale;

            mainHandler.removeCallbacks(workspaceRestoreRunnable);
            if (isOpening) {
                workspaceRecededForAppOpen = true;
                lastOpenTiltX = tiltX;
                lastOpenTiltY = tiltY;
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_SCALE_XY,
                        ws.getScaleX(), depthScale, -0.35f, 0.90f, spec.perspectiveResponseSec * 0.85f);
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_ROTATION_X,
                        ws.getRotationX(), tiltX, tiltX * 2.2f, 0.90f, spec.perspectiveResponseSec * 0.85f);
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_ROTATION_Y,
                        ws.getRotationY(), tiltY, tiltY * 2.2f, 0.90f, spec.perspectiveResponseSec * 0.85f);
                // Safety auto-restore once the launched app fully occludes the launcher
                mainHandler.postDelayed(workspaceRestoreRunnable, 480L);
            } else {
                // Closing app back to Home: emerge smoothly out of 3D perspective with organic iOS 27 bounce!
                float startScale = workspaceRecededForAppOpen ? ws.getScaleX() : depthScale;
                float startRotX = workspaceRecededForAppOpen ? ws.getRotationX()
                        : (Math.abs(lastOpenTiltX) > 0.2f ? lastOpenTiltX : tiltX);
                float startRotY = workspaceRecededForAppOpen ? ws.getRotationY()
                        : (Math.abs(lastOpenTiltY) > 0.2f ? lastOpenTiltY : tiltY);
                workspaceRecededForAppOpen = false;
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_SCALE_XY,
                        startScale, 1.0f, 0.42f, spec.perspectiveDamping, spec.perspectiveResponseSec);
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_ROTATION_X,
                        startRotX, 0.0f, -startRotX * 2.4f, spec.perspectiveDamping, spec.perspectiveResponseSec);
                choreographer.springTo(ws, CoreSurfaceChoreographer.PROP_ROTATION_Y,
                        startRotY, 0.0f, -startRotY * 2.4f, spec.perspectiveDamping, spec.perspectiveResponseSec);
            }
            telemetry.incCurvesApplied();
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
                    // Explicitly skip alpha & corner-radius springs to prevent flash/clip glitches
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

    private View getWorkspaceView() {
        View ws = workspaceViewRef.get();
        if (ws != null && ws.isAttachedToWindow()) {
            return ws;
        }
        Activity act = launcherActivityRef.get();
        if (act == null) {
            return null;
        }
        ws = findViewByClassHint(getDecorView(act), "workspace", true);
        if (ws != null) {
            workspaceViewRef = new WeakReference<>(ws);
        }
        return ws;
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
        if (cls.contains("celllayout") && node instanceof ViewGroup) {
            node.getLocationOnScreen(loc);
            // Only pick the active on-screen Home Screen page (skip off-screen pages & -1 Screen)
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
