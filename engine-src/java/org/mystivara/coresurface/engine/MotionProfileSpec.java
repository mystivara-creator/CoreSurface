package org.mystivara.coresurface.engine;

/**
 * First-Principles Per-Channel Physics Specifications for CoreSurface Motion Engine.
 *
 * Honest, zero-gimmick motion feels with genuine, immediately noticeable physical contrast
 * across App Open/Close (RectFSpringAnim), Control Center & Folders (Folme + Choreographer),
 * and Page/Activity Transitions (WMShell SurfaceControl) — WITHOUT touching Android's
 * 3 Developer Options animation scale settings and keeping Lock-to-Home 100% stock HyperOS:
 *
 * - `off`:    Stock Flagship (100% pure native Xiaomi Folme, zero intervention)
 * - `snappy`: Snappy (ultra-fast, crisp, high-stiffness takeoff & ~220ms razor-sharp settle)
 * - `fluid`:  Fluid (heavy, viscous, silky weighted glide with ~560ms smooth deceleration tail)
 * - `bouncy`: Bouncy (genuine under-damped elastic spring, zeta~0.66, visible ~7% overshoot catch)
 */
public final class MotionProfileSpec {
    public static final String PROFILE_OFF = "off";
    public static final String PROFILE_SNAPPY = "snappy";
    public static final String PROFILE_FLUID = "fluid";
    public static final String PROFILE_BOUNCY = "bouncy";

    // Legacy v1.1/v1.2 aliases preserved for seamless config upgrades
    public static final String LEGACY_COLOROS = "coloros";
    public static final String LEGACY_SILK = "silk";
    public static final String LEGACY_HYPEROS4 = "hyperos4";
    public static final String LEGACY_IOS = "ios";

    public final String profileId;

    // 1. WMShell SurfaceControl Page & Activity Transitions (com.android.systemui)
    public final float shellDamping;
    public final float shellResponseSec;
    public final float shellInitialVelocity;
    public final boolean shellAllowOvershoot;
    public final float shellMaxOvershoot;
    public final long shellSettleMs;

    // 2. Launcher App Open/Close & Swipe-Home (RectFSpringAnim in com.miui.home)
    public final float appPosDamping;
    public final float appPosResponseSec;
    public final float appScaleDamping;
    public final float appScaleResponseSec;
    public final float appVelocityScale;

    // 3. Choreographer Interactive Surface Choreography (Control Center & Folders)
    public final float surfaceDamping;
    public final float surfaceResponseSec;
    public final float surfaceLiftDp;
    public final float surfaceImpulseVel;

    // 4. Native Folme & Jetpack SpringForce Strong Calibration
    public final float folmeDamping;
    public final float folmeResponseSec;
    public final float folmeStiffnessK;
    public final float folmeBlendWeight;

    private MotionProfileSpec(
            String profileId,
            float shellDamping, float shellResponseSec, float shellInitialVelocity,
            boolean shellAllowOvershoot, float shellMaxOvershoot,
            float appPosDamping, float appPosResponseSec,
            float appScaleDamping, float appScaleResponseSec, float appVelocityScale,
            float surfaceDamping, float surfaceResponseSec, float surfaceLiftDp, float surfaceImpulseVel,
            float folmeDamping, float folmeResponseSec, float folmeBlendWeight) {
        this.profileId = profileId;
        this.shellDamping = shellDamping;
        this.shellResponseSec = shellResponseSec;
        this.shellInitialVelocity = shellInitialVelocity;
        this.shellAllowOvershoot = shellAllowOvershoot;
        this.shellMaxOvershoot = shellMaxOvershoot;
        double settleSec = CoreSpringSolver.computeSettleTimeSec(
                shellDamping, shellResponseSec, shellInitialVelocity, 0.004);
        this.shellSettleMs = Math.round(settleSec * 1000.0);

        this.appPosDamping = appPosDamping;
        this.appPosResponseSec = appPosResponseSec;
        this.appScaleDamping = appScaleDamping;
        this.appScaleResponseSec = appScaleResponseSec;
        this.appVelocityScale = appVelocityScale;

        this.surfaceDamping = surfaceDamping;
        this.surfaceResponseSec = surfaceResponseSec;
        this.surfaceLiftDp = surfaceLiftDp;
        this.surfaceImpulseVel = surfaceImpulseVel;

        this.folmeDamping = folmeDamping;
        this.folmeResponseSec = folmeResponseSec;
        double omegaN = (2.0 * Math.PI) / folmeResponseSec;
        this.folmeStiffnessK = (float) (omegaN * omegaN);
        this.folmeBlendWeight = folmeBlendWeight;
    }

    public static MotionProfileSpec forProfile(String rawProfile, float refreshHz, float thermalScale) {
        String profile = normalizeProfile(rawProfile);
        float hz = clamp((refreshHz - 60.0f) / 60.0f, 0.0f, 1.0f);
        float w = clamp(thermalScale, 0.35f, 1.0f);

        if (PROFILE_BOUNCY.equals(profile)) {
            // Bouncy: unmistakable under-damped elastic spring (zeta ~ 0.66 -> ~6.5% real overshoot)
            // across App Open/Close, Control Center, Folders & Page Transitions.
            float shDamp = lerp(0.80f, 0.68f, w);
            float shResp = lerp(lerp(0.35f, 0.38f, w), lerp(0.38f, 0.41f, w), hz);
            float shV0 = lerp(0.90f, 1.45f, w);

            float appPDamp = lerp(0.78f, 0.66f, w);
            float appPResp = lerp(lerp(0.35f, 0.38f, w), lerp(0.38f, 0.41f, w), hz);
            float appSDamp = lerp(0.80f, 0.70f, w);
            float appSResp = lerp(lerp(0.37f, 0.40f, w), lerp(0.40f, 0.43f, w), hz);
            float appVel = lerp(1.08f, 1.18f, w);

            float surfDamp = lerp(0.76f, 0.62f, w);
            float surfResp = lerp(lerp(0.36f, 0.40f, w), lerp(0.39f, 0.43f, w), hz);
            float surfLift = lerp(14.0f, 26.0f, w);
            float surfVel = lerp(1.5f, 2.5f, w);

            float fDamp = lerp(0.78f, 0.66f, w);
            float fResp = lerp(lerp(0.35f, 0.38f, w), lerp(0.37f, 0.40f, w), hz);

            return new MotionProfileSpec(
                    PROFILE_BOUNCY,
                    shDamp, shResp, shV0, (w >= 0.45f), 1.07f,
                    appPDamp, appPResp, appSDamp, appSResp, appVel,
                    surfDamp, surfResp, surfLift, surfVel,
                    fDamp, fResp, lerp(0.55f, 0.85f, w));
        }

        if (PROFILE_SNAPPY.equals(profile)) {
            // Snappy: ultra-fast, high-stiffness, razor-sharp settle (~220ms) with explosive launch
            // and zero sluggish tail — without touching Developer Options animation scales.
            float shDamp = lerp(0.97f, 0.94f, w);
            float shResp = lerp(lerp(0.22f, 0.19f, w), lerp(0.23f, 0.20f, w), hz);
            float shV0 = lerp(1.50f, 2.30f, w);

            float appPDamp = lerp(0.95f, 0.92f, w);
            float appPResp = lerp(lerp(0.22f, 0.19f, w), lerp(0.23f, 0.20f, w), hz);
            float appSDamp = lerp(0.96f, 0.94f, w);
            float appSResp = lerp(lerp(0.23f, 0.20f, w), lerp(0.24f, 0.21f, w), hz);
            float appVel = lerp(1.12f, 1.24f, w);

            float surfDamp = lerp(0.96f, 0.93f, w);
            float surfResp = lerp(lerp(0.21f, 0.18f, w), lerp(0.22f, 0.19f, w), hz);
            float surfLift = lerp(6.0f, 10.0f, w);
            float surfVel = lerp(1.8f, 3.0f, w);

            float fDamp = lerp(0.96f, 0.93f, w);
            float fResp = lerp(lerp(0.21f, 0.18f, w), lerp(0.22f, 0.19f, w), hz);

            return new MotionProfileSpec(
                    PROFILE_SNAPPY,
                    shDamp, shResp, shV0, false, 1.0f,
                    appPDamp, appPResp, appSDamp, appSResp, appVel,
                    surfDamp, surfResp, surfLift, surfVel,
                    fDamp, fResp, lerp(0.55f, 0.85f, w));
        }

        // Fluid (default active fallback): heavy, silky, cushioned glide with rich deceleration tail
        float shDamp = lerp(0.99f, 0.98f, w);
        float shResp = lerp(lerp(0.42f, 0.48f, w), lerp(0.45f, 0.51f, w), hz);
        float shV0 = lerp(0.35f, 0.45f, w);

        float appPDamp = lerp(0.98f, 0.96f, w);
        float appPResp = lerp(lerp(0.43f, 0.48f, w), lerp(0.46f, 0.52f, w), hz);
        float appSDamp = lerp(0.99f, 0.97f, w);
        float appSResp = lerp(lerp(0.45f, 0.50f, w), lerp(0.48f, 0.54f, w), hz);
        float appVel = lerp(0.95f, 0.98f, w);

        float surfDamp = lerp(0.98f, 0.96f, w);
        float surfResp = lerp(lerp(0.42f, 0.48f, w), lerp(0.45f, 0.51f, w), hz);
        float surfLift = lerp(10.0f, 18.0f, w);
        float surfVel = lerp(0.7f, 1.1f, w);

        float fDamp = lerp(0.98f, 0.96f, w);
        float fResp = lerp(lerp(0.42f, 0.48f, w), lerp(0.45f, 0.50f, w), hz);

        return new MotionProfileSpec(
                PROFILE_FLUID,
                shDamp, shResp, shV0, false, 1.0f,
                appPDamp, appPResp, appSDamp, appSResp, appVel,
                surfDamp, surfResp, surfLift, surfVel,
                fDamp, fResp, lerp(0.55f, 0.82f, w));
    }

    public static String normalizeProfile(String raw) {
        if (raw == null) {
            return PROFILE_OFF;
        }
        if (PROFILE_BOUNCY.equals(raw) || LEGACY_IOS.equals(raw)) {
            return PROFILE_BOUNCY;
        }
        if (PROFILE_SNAPPY.equals(raw) || LEGACY_COLOROS.equals(raw) || LEGACY_SILK.equals(raw)) {
            return PROFILE_SNAPPY;
        }
        if (PROFILE_FLUID.equals(raw) || LEGACY_HYPEROS4.equals(raw)) {
            return PROFILE_FLUID;
        }
        return PROFILE_OFF;
    }

    public static float responseToStiffness(float responseSec) {
        double wn = (2.0 * Math.PI) / clamp(responseSec, 0.14f, 0.85f);
        return (float) (wn * wn);
    }

    private static float lerp(float a, float b, float t) {
        return a + (b - a) * t;
    }

    private static float clamp(float v, float min, float max) {
        return Math.max(min, Math.min(max, v));
    }
}
