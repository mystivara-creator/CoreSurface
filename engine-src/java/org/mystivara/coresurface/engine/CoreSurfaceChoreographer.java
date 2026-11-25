package org.mystivara.coresurface.engine;

import android.os.Looper;
import android.view.Choreographer;
import android.view.View;

import java.lang.ref.WeakReference;

/**
 * Zero-Allocation VSync Choreographer Physics Driver for Interactive Surfaces.
 *
 * Drives real View transforms directly from CoreSpringSolver on every Choreographer VSync:
 * - Fixed 16-slot pool: ZERO heap allocation per VSync frame.
 * - True mid-flight interruptibility: retargeting an active (view, property) keeps its exact
 *   current (position, velocity) and bends smoothly to the new target without snapping.
 * - Strictly 0% CPU/GPU idle overhead: unregisters FrameCallback immediately when all slots settle.
 * - Leak-proof: holds WeakReference<View> and auto-cancels detached views.
 */
public final class CoreSurfaceChoreographer implements Choreographer.FrameCallback {
    public static final int PROP_TRANSLATION_Y = 1;
    public static final int PROP_TRANSLATION_X = 2;
    public static final int PROP_SCALE_XY = 3;
    public static final int PROP_ROTATION_X = 4;
    public static final int PROP_ROTATION_Y = 5;
    public static final int PROP_ALPHA = 6;

    // 192 pre-allocated slots (~18 KB RAM, ZERO per-frame heap allocation):
    // supports full 3D staggered Home Screen unlock (32+ icons x 5 axes + Hotseat + Workspace)
    private static final int MAX_SLOTS = 192;
    private static final double EPS_PX = 0.25;
    private static final double EPS_PX_VEL = 4.0;
    private static final double EPS_SCALE = 0.0015;
    private static final double EPS_SCALE_VEL = 0.025;
    private static final double EPS_DEG = 0.06;
    private static final double EPS_DEG_VEL = 0.8;
    private static final double EPS_ALPHA = 0.008;
    private static final double EPS_ALPHA_VEL = 0.06;
    private static final double NS_TO_SEC = 1e-9;

    private static final class TrackSlot {
        boolean active;
        WeakReference<View> viewRef;
        int viewIdentity;
        int propId;
        double delayRemainSec;
        final CoreSpringSolver solver = new CoreSpringSolver();
    }

    private final TrackSlot[] slots = new TrackSlot[MAX_SLOTS];
    private final TelemetryReporter telemetry;
    private boolean running = false;
    private long lastFrameNanos = 0L;

    public CoreSurfaceChoreographer(TelemetryReporter telemetry) {
        this.telemetry = telemetry;
        for (int i = 0; i < MAX_SLOTS; i++) {
            slots[i] = new TrackSlot();
        }
    }

    /**
     * Starts or mid-flight retargets a physical spring on a View property immediately.
     * Must be invoked on the main (UI) thread.
     */
    public void springTo(View view, int propId, float startFromIfNew, float target,
                         float initialVelocityPerSec, float dampingRatio, float responseSec) {
        springToDelayed(view, propId, startFromIfNew, target, initialVelocityPerSec,
                dampingRatio, responseSec, 0.0f);
    }

    /**
     * Starts or mid-flight retargets a physical spring on a View property with optional stagger delay.
     * During delay, the view holds `startFromIfNew` cleanly, then springs seamlessly on VSync.
     */
    public void springToDelayed(View view, int propId, float startFromIfNew, float target,
                                float initialVelocityPerSec, float dampingRatio, float responseSec,
                                float delaySec) {
        if (view == null || Looper.myLooper() != Looper.getMainLooper()) {
            return;
        }
        if (propId == PROP_ROTATION_X || propId == PROP_ROTATION_Y) {
            ensurePerspectiveCamera(view);
        }
        int identity = System.identityHashCode(view);
        TrackSlot slot = findSlot(identity, propId);
        if (slot != null && slot.active) {
            // True mid-flight interruptibility: keep live (x, v), just retarget & update spring params
            slot.viewRef = new WeakReference<>(view);
            slot.delayRemainSec = 0.0;
            slot.solver.configure(dampingRatio, responseSec);
            slot.solver.retarget(target);
        } else {
            slot = acquireFreeSlot();
            if (slot == null) {
                return;
            }
            slot.active = true;
            slot.viewRef = new WeakReference<>(view);
            slot.viewIdentity = identity;
            slot.propId = propId;
            slot.delayRemainSec = Math.max(0.0, delaySec);
            slot.solver.configure(dampingRatio, responseSec);
            slot.solver.reset(startFromIfNew, target, initialVelocityPerSec);
            applyProperty(view, propId, startFromIfNew);
            if (telemetry != null) {
                telemetry.incSpringsTuned();
            }
        }
        ensureRunning();
    }

    /**
     * Smoothly cancels any active track on the given (View, property) and restores its resting value.
     */
    public void cancelAndReset(View view, int propId) {
        if (view == null || Looper.myLooper() != Looper.getMainLooper()) {
            return;
        }
        TrackSlot slot = findSlot(System.identityHashCode(view), propId);
        if (slot != null && slot.active) {
            slot.active = false;
            slot.viewRef = null;
            slot.delayRemainSec = 0.0;
            applyProperty(view, propId, restValueFor(propId));
        }
    }

    /**
     * Cancels all active spring tracks on the given View and snaps every animated axis to rest.
     */
    public void cancelAllForView(View view) {
        if (view == null || Looper.myLooper() != Looper.getMainLooper()) {
            return;
        }
        int identity = System.identityHashCode(view);
        for (int i = 0; i < MAX_SLOTS; i++) {
            TrackSlot slot = slots[i];
            if (slot.active && slot.viewIdentity == identity) {
                slot.active = false;
                slot.viewRef = null;
                slot.delayRemainSec = 0.0;
                applyProperty(view, slot.propId, restValueFor(slot.propId));
            }
        }
    }

    @Override
    public void doFrame(long frameTimeNanos) {
        double dtSec = (lastFrameNanos > 0L && frameTimeNanos > lastFrameNanos)
                ? (frameTimeNanos - lastFrameNanos) * NS_TO_SEC
                : (1.0 / 60.0);
        lastFrameNanos = frameTimeNanos;

        int stillActive = 0;
        for (int i = 0; i < MAX_SLOTS; i++) {
            TrackSlot slot = slots[i];
            if (!slot.active) {
                continue;
            }
            View v = slot.viewRef != null ? slot.viewRef.get() : null;
            if (v == null || !v.isAttachedToWindow()) {
                slot.active = false;
                slot.viewRef = null;
                continue;
            }

            if (slot.delayRemainSec > 0.0) {
                slot.delayRemainSec -= dtSec;
                stillActive++;
                continue;
            }

            double next = slot.solver.step(dtSec);
            if (isSlotAtRest(slot)) {
                slot.solver.snapToTarget();
                applyProperty(v, slot.propId, (float) slot.solver.getTarget());
                slot.active = false;
                slot.viewRef = null;
            } else {
                applyProperty(v, slot.propId, (float) next);
                stillActive++;
            }
        }

        if (stillActive > 0) {
            Choreographer.getInstance().postFrameCallback(this);
        } else {
            running = false;
            lastFrameNanos = 0L;
        }
    }

    private static boolean isSlotAtRest(TrackSlot slot) {
        switch (slot.propId) {
            case PROP_SCALE_XY:
                return slot.solver.isAtRest(EPS_SCALE, EPS_SCALE_VEL);
            case PROP_ROTATION_X:
            case PROP_ROTATION_Y:
                return slot.solver.isAtRest(EPS_DEG, EPS_DEG_VEL);
            case PROP_ALPHA:
                return slot.solver.isAtRest(EPS_ALPHA, EPS_ALPHA_VEL);
            default:
                return slot.solver.isAtRest(EPS_PX, EPS_PX_VEL);
        }
    }

    private static float restValueFor(int propId) {
        if (propId == PROP_SCALE_XY || propId == PROP_ALPHA) {
            return 1.0f;
        }
        return 0.0f;
    }

    private static void ensurePerspectiveCamera(View v) {
        try {
            float density = v.getResources() != null
                    ? v.getResources().getDisplayMetrics().density : 2.75f;
            // Balanced 3D perspective camera distance (~1280dp equivalent in px):
            // crisp depth perception without extreme fish-eye distortion
            float desired = 1280.0f * density * density;
            if (Math.abs(v.getCameraDistance() - desired) > 100.0f) {
                v.setCameraDistance(desired);
            }
        } catch (Throwable ignored) {
        }
    }

    private void ensureRunning() {
        if (!running) {
            running = true;
            lastFrameNanos = 0L;
            Choreographer.getInstance().postFrameCallback(this);
        }
    }

    private TrackSlot findSlot(int identity, int propId) {
        for (int i = 0; i < MAX_SLOTS; i++) {
            TrackSlot s = slots[i];
            if (s.active && s.viewIdentity == identity && s.propId == propId) {
                return s;
            }
        }
        return null;
    }

    private TrackSlot acquireFreeSlot() {
        for (int i = 0; i < MAX_SLOTS; i++) {
            if (!slots[i].active) {
                return slots[i];
            }
        }
        return null;
    }

    private static void applyProperty(View v, int propId, float value) {
        try {
            switch (propId) {
                case PROP_TRANSLATION_Y:
                    v.setTranslationY(value);
                    break;
                case PROP_TRANSLATION_X:
                    v.setTranslationX(value);
                    break;
                case PROP_SCALE_XY:
                    float sc = Math.max(0.55f, Math.min(1.60f, value));
                    v.setScaleX(sc);
                    v.setScaleY(sc);
                    break;
                case PROP_ROTATION_X:
                    v.setRotationX(Math.max(-22.0f, Math.min(22.0f, value)));
                    break;
                case PROP_ROTATION_Y:
                    v.setRotationY(Math.max(-22.0f, Math.min(22.0f, value)));
                    break;
                case PROP_ALPHA:
                    v.setAlpha(Math.max(0.0f, Math.min(1.0f, value)));
                    break;
                default:
                    break;
            }
        } catch (Throwable ignored) {
        }
    }
}
