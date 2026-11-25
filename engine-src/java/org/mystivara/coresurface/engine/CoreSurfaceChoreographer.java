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

    private static final int MAX_SLOTS = 16;
    private static final double EPS_PX = 0.25;
    private static final double EPS_VEL = 4.0;
    private static final double NS_TO_SEC = 1e-9;

    private static final class TrackSlot {
        boolean active;
        WeakReference<View> viewRef;
        int viewIdentity;
        int propId;
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
     * Starts or mid-flight retargets a physical spring on a View property.
     * Must be invoked on the main (UI) thread.
     */
    public void springTo(View view, int propId, float startFromIfNew, float target,
                         float initialVelocityPxPerSec, float dampingRatio, float responseSec) {
        if (view == null || Looper.myLooper() != Looper.getMainLooper()) {
            return;
        }
        int identity = System.identityHashCode(view);
        TrackSlot slot = findSlot(identity, propId);
        if (slot != null && slot.active) {
            // True mid-flight interruptibility: keep live (x, v), just retarget & update spring params
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
            slot.solver.reset(startFromIfNew, target, initialVelocityPxPerSec);
            applyProperty(view, propId, startFromIfNew);
            if (telemetry != null) {
                telemetry.incSpringsTuned();
            }
        }
        ensureRunning();
    }

    /**
     * Smoothly cancels or snaps any active track on the given View back to rest (0f).
     */
    public void cancelAndReset(View view, int propId) {
        if (view == null || Looper.myLooper() != Looper.getMainLooper()) {
            return;
        }
        TrackSlot slot = findSlot(System.identityHashCode(view), propId);
        if (slot != null && slot.active) {
            slot.active = false;
            slot.viewRef = null;
            applyProperty(view, propId, 0.0f);
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

            double next = slot.solver.step(dtSec);
            if (slot.solver.isAtRest(EPS_PX, EPS_VEL)) {
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
            if (propId == PROP_TRANSLATION_Y) {
                v.setTranslationY(value);
            } else if (propId == PROP_TRANSLATION_X) {
                v.setTranslationX(value);
            }
        } catch (Throwable ignored) {
        }
    }
}
