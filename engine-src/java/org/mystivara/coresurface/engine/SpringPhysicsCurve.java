package org.mystivara.coresurface.engine;

/**
 * Lightweight Analytical Spring Parameters for CoreSurface Native Folme Refinement.
 *
 * Computes physically consistent damping ratio (zeta), response period (T), and
 * spring stiffness k = (2 * pi / T)^2 scaled smoothly for 60–144 Hz panels and
 * thermal LOD tiers. Zero synthetic bounce, zero duration stretching, zero LUT overhead.
 */
public final class SpringPhysicsCurve {
    private final float dampingRatio;
    private final float responseSec;
    private final float stiffnessK;

    public SpringPhysicsCurve(float dampingRatio, float responseSec) {
        this.dampingRatio = clamp(dampingRatio, 0.78f, 1.0f);
        this.responseSec = clamp(responseSec, 0.18f, 0.55f);
        double omegaN = (2.0 * Math.PI) / this.responseSec;
        this.stiffnessK = (float) (omegaN * omegaN);
    }

    public static SpringPhysicsCurve forProfile(String profile, float refreshHz, float thermalScale) {
        // Continuous refresh-rate interpolation: 0.0 at 60 Hz -> 0.5 at 90 Hz -> 1.0 at 120 Hz+
        float hzFactor = clamp((refreshHz - 60.0f) / 60.0f, 0.0f, 1.0f);
        float w = clamp(thermalScale, 0.30f, 1.0f);

        float zeta;
        float response;
        if (EngineConfig.MOTION_SILK.equals(profile)) {
            // Smooth Flow: subtly softer, fluid settle without artificial wobble or sluggishness
            float zeta60 = lerp(0.90f, 0.86f, w);
            float zeta120 = lerp(0.88f, 0.84f, w);
            float resp60 = lerp(0.34f, 0.36f, w);
            float resp120 = lerp(0.36f, 0.40f, w);
            zeta = lerp(zeta60, zeta120, hzFactor);
            response = lerp(resp60, resp120, hzFactor);
        } else {
            // Flagship Crisp (hyperos4): taut, responsive, zero-overshoot flagship spring
            float zeta60 = lerp(0.95f, 0.93f, w);
            float zeta120 = lerp(0.93f, 0.91f, w);
            float resp60 = lerp(0.26f, 0.28f, w);
            float resp120 = lerp(0.28f, 0.32f, w);
            zeta = lerp(zeta60, zeta120, hzFactor);
            response = lerp(resp60, resp120, hzFactor);
        }
        return new SpringPhysicsCurve(zeta, response);
    }

    public float getDampingRatio() {
        return dampingRatio;
    }

    public float getResponseSec() {
        return responseSec;
    }

    public float getStiffnessK() {
        return stiffnessK;
    }

    private static float lerp(float a, float b, float t) {
        return a + (b - a) * t;
    }

    private static float clamp(float v, float min, float max) {
        return Math.max(min, Math.min(max, v));
    }
}
