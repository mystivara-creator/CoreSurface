package org.mystivara.coresurface.engine;

import android.os.Looper;
import android.view.Choreographer;
import android.view.View;

import java.lang.ref.WeakReference;

/**
 * Zero-Allocation VSync Choreographer Physics Driver for Interactive Surfaces (Control Center & Folders).
 *
 * - Lean 16-slot fixed pool (~1.5 KB RAM, ZERO per-frame heap allocation).
 * - Refresh-rate aware frame-0 dt (adapts to 60/90/120/144 Hz cleanly without oversized first step).
 * - True mid-flight interruptibility: retargeting an active (view, property) keeps exact (x, v).
 * - Strictly 0% CPU/GPU idle overhead: unregisters FrameCallback immediately when all slots settle.
 */
public final class CoreSurfaceChoreographer implements Choreographer.FrameCallback {
    public static final int PROP_TRANSLATION_Y = 1;
    public static final int PROP_TRANSLATION_X = 2;
    public static final int PROP_SCALE_XY = 3;

    private static final int MAX_SLOTS = 16;
    private static final double EPS_PX = 0.25;
    private static final double EPS_PX_VEL = 4.0;
    private static final double EPS_SCALE = 0.0015;
    private static final double EPS_SCALE_VEL = 0.025;
    private static final double NS_TO_SEC = 1e-9;

    private static final class TrackSlot {
        boolean active;
        WeakReference<View> viewRef;
        int viewIdentity;
        int propId;
        final CoreSpringSolver solver = new CoreSpringSolver();
    }

    private final TrackSlot[] slots = new TrackSlot[MAX_SLOTS];
    private final FolmePhysicsHook specHub;
    private final TelemetryReporter telemetry;
    private boolean running = false;
    private long lastFrameNanos = 0L;

    public CoreSurfaceChoreographer(FolmePhysicsHook specHub, TelemetryReporter telemetry) {
        this.specHub = specHub;
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
        if (view == null || Looper.myLooper() != Looper.getMainLooper()) {
            return;
        }
        int identity = System.identityHashCode(view);
        TrackSlot slot = findSlot(identity, propId);
        if (slot != null && slot.active) {
            slot.viewRef = new WeakReference<>(view);
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
            applyProperty(view, propId, restValueFor(propId));
        }
    }

    /**
     * Immediately cancels EVERY active spring track and restores every tracked View to exact rest.
     */
    public void cancelAllActive() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            return;
        }
        for (int i = 0; i < MAX_SLOTS; i++) {
            TrackSlot slot = slots[i];
            if (!slot.active) {
                continue;
            }
            View v = slot.viewRef != null ? slot.viewRef.get() : null;
            slot.active = false;
            slot.viewRef = null;
            if (v != null && v.isAttachedToWindow()) {
                applyProperty(v, slot.propId, restValueFor(slot.propId));
            }
        }
        if (running) {
            running = false;
            lastFrameNanos = 0L;
            try {
                Choreographer.getInstance().removeFrameCallback(this);
            } catch (Throwable ignored) {
            }
        }
    }

    @Override
    public void doFrame(long frameTimeNanos) {
        double dtSec;
        if (lastFrameNanos > 0L && frameTimeNanos > lastFrameNanos) {
            dtSec = (frameTimeNanos - lastFrameNanos) * NS_TO_SEC;
        } else {
            float hz = specHub != null ? specHub.getCurrentRefreshHz() : 60.0f;
            dtSec = 1.0 / Math.max(60.0f, Math.min(240.0f, hz));
        }
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
        if (slot.propId == PROP_SCALE_XY) {
            return slot.solver.isAtRest(EPS_SCALE, EPS_SCALE_VEL);
        }
        return slot.solver.isAtRest(EPS_PX, EPS_PX_VEL);
    }

    private static float restValueFor(int propId) {
        return propId == PROP_SCALE_XY ? 1.0f : 0.0f;
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
                default:
                    break;
            }
        } catch (Throwable ignored) {
        }
    }
}
