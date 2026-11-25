package org.mystivara.coresurface.engine;

import android.view.Choreographer;

/**
 * Zero-dependency LivingFlow Spring Physics Engine.
 * Integrates a damped harmonic oscillator synchronized directly to Android's
 * display VSync (60/90/120 Hz) via Choreographer. Supports smooth interruptible
 * retargeting with velocity conservation.
 */
public final class SpringPhysics {
    public interface UpdateListener {
        void onUpdate(float value);
    }

    private final float stiffness;
    private final float dampingRatio;
    private final float epsilon;
    private final UpdateListener listener;
    private final Runnable onEnd;

    private float value;
    private float target;
    private float velocity;
    private long lastFrameNanos;
    private boolean running;

    private final Choreographer.FrameCallback frameCallback = new Choreographer.FrameCallback() {
        @Override
        public void doFrame(long frameTimeNanos) {
            if (!running) {
                return;
            }
            float dt;
            if (lastFrameNanos <= 0L) {
                dt = 1.0f / 120.0f;
            } else {
                dt = (frameTimeNanos - lastFrameNanos) * 1e-9f;
                // Clamp dt to keep integration unconditionally stable across frame drops
                if (dt > 0.032f) {
                    dt = 0.032f;
                } else if (dt < 0.001f) {
                    dt = 0.001f;
                }
            }
            lastFrameNanos = frameTimeNanos;

            // Sub-step twice for high-stiffness stability at any refresh rate
            float subDt = dt * 0.5f;
            float damping = (float) (2.0 * dampingRatio * Math.sqrt(stiffness));
            for (int i = 0; i < 2; i++) {
                float force = -stiffness * (value - target) - damping * velocity;
                velocity += force * subDt;
                value += velocity * subDt;
            }

            boolean settled = Math.abs(value - target) < epsilon && Math.abs(velocity) < epsilon * 12.0f;
            if (settled) {
                value = target;
                velocity = 0.0f;
                running = false;
                dispatchUpdate(value);
                if (onEnd != null) {
                    try {
                        onEnd.run();
                    } catch (Throwable ignored) {
                    }
                }
                return;
            }

            dispatchUpdate(value);
            Choreographer.getInstance().postFrameCallback(this);
        }
    };

    public SpringPhysics(float initialValue, float stiffness, float dampingRatio, float epsilon,
                         UpdateListener listener, Runnable onEnd) {
        this.value = initialValue;
        this.target = initialValue;
        this.stiffness = stiffness;
        this.dampingRatio = dampingRatio;
        this.epsilon = epsilon;
        this.listener = listener;
        this.onEnd = onEnd;
    }

    public void animateTo(float newTarget) {
        this.target = newTarget;
        if (!running) {
            running = true;
            lastFrameNanos = 0L;
            Choreographer.getInstance().postFrameCallback(frameCallback);
        }
    }

    public void animateTo(float newTarget, float initialVelocity) {
        this.velocity = initialVelocity;
        animateTo(newTarget);
    }

    public void cancel() {
        if (running) {
            running = false;
            try {
                Choreographer.getInstance().removeFrameCallback(frameCallback);
            } catch (Throwable ignored) {
            }
        }
    }

    public float getValue() {
        return value;
    }

    private void dispatchUpdate(float v) {
        if (listener != null) {
            try {
                listener.onUpdate(v);
            } catch (Throwable ignored) {
            }
        }
    }
}
