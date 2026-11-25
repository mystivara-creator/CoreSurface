package org.mystivara.coresurface.engine;

/**
 * Unified Folme/SpringForce Parameter Adapter backed by MotionProfileSpec.
 */
public final class SpringPhysicsCurve {
    private final MotionProfileSpec spec;

    public SpringPhysicsCurve(MotionProfileSpec spec) {
        this.spec = spec;
    }

    public static SpringPhysicsCurve forProfile(String profile, float refreshHz, float thermalScale) {
        return new SpringPhysicsCurve(MotionProfileSpec.forProfile(profile, refreshHz, thermalScale));
    }

    public MotionProfileSpec getSpec() {
        return spec;
    }

    public float getDampingRatio() {
        return spec.folmeDamping;
    }

    public float getResponseSec() {
        return spec.folmeResponseSec;
    }

    public float getStiffnessK() {
        return spec.folmeStiffnessK;
    }

    public float getBlendWeight() {
        return spec.folmeBlendWeight;
    }
}
