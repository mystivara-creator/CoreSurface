package org.mystivara.coresurface.engine;

/**
 * First-Principles Per-Channel Physics Specifications for CoreSurface Motion Profiles.
 *
 * Separates distinct real-world motion philosophies instead of applying one global curve:
 * - `off`:      Stock Flagship (100% pure native Xiaomi Folme, zero intervention)
 * - `ios`:      iOS Fluid (Apple CASpringAnimation mass-weighted critically-damped glide,
 *               zero artificial wobble, smooth continuous deceleration tail)
 * - `coloros`:  ColorOS Quantum (OPPO Quantum Parallel physics: explosive initial launch,
 *               fast mid-flight retargeting, subtle organic spatial cushion <= 1.5%)
 * - `hyperos4`: HyperOS 4 Crisp (taut, agile, zero-overshoot flagship precision)
 */
public final class MotionProfileSpec {
    public static final String PROFILE_OFF = "off";
    public static final String PROFILE_IOS = "ios";
    public static final String PROFILE_COLOROS = "coloros";
    public static final String PROFILE_HYPEROS4 = "hyperos4";
    public static final String PROFILE_SILK_ALIAS = "silk";

    public final String profileId;

    // 1. WMShell SurfaceControl Window Transitions (com.android.systemui)
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

    // 3. Choreographer Interactive Surface Choreography (Folder & Control Center)
    public final float surfaceDamping;
    public final float surfaceResponseSec;
    public final float surfaceLiftDp;
    public final float surfaceImpulseVel;

    // 4. Native Folme & Jetpack SpringForce Gentle Calibration
    public final float folmeDamping;
    public final float folmeResponseSec;
    public final float folmeStiffnessK;
    public final float folmeBlendWeight;

    // 5. iOS 27 3D Perspective App Open/Close & Bouncy Lock-to-Home Choreography (PROFILE_IOS only)
    public final boolean ios3dPerspectiveEnabled;
    public final float perspectiveMaxTiltXDeg;
    public final float perspectiveMaxTiltYDeg;
    public final float perspectiveDepthScale;
    public final float perspectiveDamping;
    public final float perspectiveResponseSec;

    public final boolean unlockBounceEnabled;
    public final float unlockDamping;
    public final float unlockResponseSec;
    public final float unlockStartScale;
    public final float unlockRadialSpreadDp;
    public final float unlockTiltXDeg;
    public final float unlockStaggerMaxSec;

    private MotionProfileSpec(
            String profileId,
            float shellDamping, float shellResponseSec, float shellInitialVelocity,
            boolean shellAllowOvershoot, float shellMaxOvershoot,
            float appPosDamping, float appPosResponseSec,
            float appScaleDamping, float appScaleResponseSec, float appVelocityScale,
            float surfaceDamping, float surfaceResponseSec, float surfaceLiftDp, float surfaceImpulseVel,
            float folmeDamping, float folmeResponseSec, float folmeBlendWeight,
            boolean ios3dPerspectiveEnabled, float perspectiveMaxTiltXDeg, float perspectiveMaxTiltYDeg,
            float perspectiveDepthScale, float perspectiveDamping, float perspectiveResponseSec,
            boolean unlockBounceEnabled, float unlockDamping, float unlockResponseSec,
            float unlockStartScale, float unlockRadialSpreadDp, float unlockTiltXDeg, float unlockStaggerMaxSec) {
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

        this.ios3dPerspectiveEnabled = ios3dPerspectiveEnabled;
        this.perspectiveMaxTiltXDeg = perspectiveMaxTiltXDeg;
        this.perspectiveMaxTiltYDeg = perspectiveMaxTiltYDeg;
        this.perspectiveDepthScale = perspectiveDepthScale;
        this.perspectiveDamping = perspectiveDamping;
        this.perspectiveResponseSec = perspectiveResponseSec;

        this.unlockBounceEnabled = unlockBounceEnabled;
        this.unlockDamping = unlockDamping;
        this.unlockResponseSec = unlockResponseSec;
        this.unlockStartScale = unlockStartScale;
        this.unlockRadialSpreadDp = unlockRadialSpreadDp;
        this.unlockTiltXDeg = unlockTiltXDeg;
        this.unlockStaggerMaxSec = unlockStaggerMaxSec;
    }

    public static MotionProfileSpec forProfile(String rawProfile, float refreshHz, float thermalScale) {
        String profile = normalizeProfile(rawProfile);
        float hz = clamp((refreshHz - 60.0f) / 60.0f, 0.0f, 1.0f);
        float w = clamp(thermalScale, 0.35f, 1.0f);

        if (PROFILE_IOS.equals(profile)) {
            // iOS 27 Fluid: Apple CASpringAnimation mass-weighted glide + true 3D perspective depth
            // on app open/close + signature bouncy radial SpringBoard Lock-to-Home fly-in.
            float shDamp = lerp(0.99f, 0.96f, w);
            float shResp = lerp(lerp(0.36f, 0.43f, w), lerp(0.39f, 0.47f, w), hz);
            float shV0 = lerp(0.45f, 0.72f, w);

            float appPDamp = lerp(0.95f, 0.90f, w);
            float appPResp = lerp(lerp(0.36f, 0.42f, w), lerp(0.39f, 0.46f, w), hz);
            float appSDamp = lerp(0.96f, 0.92f, w);
            float appSResp = lerp(lerp(0.38f, 0.44f, w), lerp(0.41f, 0.48f, w), hz);
            float appVel = lerp(1.02f, 1.07f, w);

            float surfDamp = lerp(0.96f, 0.91f, w);
            float surfResp = lerp(lerp(0.36f, 0.41f, w), lerp(0.39f, 0.44f, w), hz);
            float surfLift = lerp(6.0f, 12.0f, w);
            float surfVel = lerp(0.8f, 1.4f, w);

            float fDamp = lerp(0.97f, 0.94f, w);
            float fResp = lerp(lerp(0.35f, 0.38f, w), lerp(0.37f, 0.41f, w), hz);

            float perspTiltX = lerp(3.2f, 7.5f, w);
            float perspTiltY = lerp(2.2f, 5.0f, w);
            float perspScale = lerp(0.945f, 0.89f, w);
            float perspDamp = lerp(0.84f, 0.72f, w);
            float perspResp = lerp(0.38f, 0.44f, hz);

            // Bouncy Lock Screen -> Home Screen fly-in (zeta=0.54 -> unmistakable elastic iOS 27 bounce)
            float unlDamp = lerp(0.70f, 0.54f, w);
            float unlResp = lerp(0.41f, 0.47f, hz);
            float unlScale = lerp(1.20f, 1.38f, w);
            float unlSpread = lerp(40.0f, 76.0f, w);
            float unlTiltX = lerp(6.5f, 13.0f, w);
            float unlStagger = lerp(0.028f, 0.055f, w);

            return new MotionProfileSpec(
                    PROFILE_IOS,
                    shDamp, shResp, shV0, false, 1.0f,
                    appPDamp, appPResp, appSDamp, appSResp, appVel,
                    surfDamp, surfResp, surfLift, surfVel,
                    fDamp, fResp, lerp(0.20f, 0.35f, w),
                    true, perspTiltX, perspTiltY, perspScale, perspDamp, perspResp,
                    true, unlDamp, unlResp, unlScale, unlSpread, unlTiltX, unlStagger);
        }

        if (PROFILE_COLOROS.equals(profile)) {
            // ColorOS Quantum: explosive snappy takeoff, parallel interruptibility, subtle cushion (<= 1.5%)
            float shDamp = lerp(0.96f, 0.90f, w);
            float shResp = lerp(lerp(0.28f, 0.32f, w), lerp(0.31f, 0.35f, w), hz);
            float shV0 = lerp(0.95f, 1.55f, w);

            float appPDamp = lerp(0.93f, 0.86f, w);
            float appPResp = lerp(lerp(0.28f, 0.31f, w), lerp(0.30f, 0.34f, w), hz);
            float appSDamp = lerp(0.94f, 0.88f, w);
            float appSResp = lerp(lerp(0.30f, 0.33f, w), lerp(0.32f, 0.36f, w), hz);
            float appVel = lerp(1.06f, 1.16f, w);

            float surfDamp = lerp(0.94f, 0.86f, w);
            float surfResp = lerp(lerp(0.28f, 0.31f, w), lerp(0.30f, 0.34f, w), hz);
            float surfLift = lerp(7.0f, 14.0f, w);
            float surfVel = lerp(1.4f, 2.6f, w);

            float fDamp = lerp(0.93f, 0.87f, w);
            float fResp = lerp(lerp(0.29f, 0.31f, w), lerp(0.31f, 0.34f, w), hz);
            return new MotionProfileSpec(
                    PROFILE_COLOROS,
                    shDamp, shResp, shV0, (w >= 0.55f), 1.015f,
                    appPDamp, appPResp, appSDamp, appSResp, appVel,
                    surfDamp, surfResp, surfLift, surfVel,
                    fDamp, fResp, lerp(0.22f, 0.40f, w),
                    false, 0.0f, 0.0f, 1.0f, 0.95f, 0.32f,
                    false, 0.95f, 0.32f, 1.0f, 0.0f, 0.0f, 0.0f);
        }

        // HyperOS 4 Crisp (default active fallback): taut, agile, zero-overshoot precision
        float shDamp = lerp(0.99f, 0.97f, w);
        float shResp = lerp(lerp(0.25f, 0.28f, w), lerp(0.27f, 0.31f, w), hz);
        float shV0 = lerp(0.75f, 1.10f, w);

        float appPDamp = lerp(0.97f, 0.95f, w);
        float appPResp = lerp(lerp(0.26f, 0.29f, w), lerp(0.28f, 0.32f, w), hz);
        float appSDamp = lerp(0.98f, 0.96f, w);
        float appSResp = lerp(lerp(0.27f, 0.30f, w), lerp(0.29f, 0.33f, w), hz);
        float appVel = lerp(1.01f, 1.04f, w);

        float surfDamp = lerp(0.98f, 0.96f, w);
        float surfResp = lerp(lerp(0.25f, 0.28f, w), lerp(0.27f, 0.30f, w), hz);
        float surfLift = lerp(4.0f, 8.0f, w);
        float surfVel = lerp(0.9f, 1.5f, w);

        float fDamp = lerp(0.97f, 0.95f, w);
        float fResp = lerp(lerp(0.25f, 0.27f, w), lerp(0.27f, 0.30f, w), hz);
        return new MotionProfileSpec(
                PROFILE_HYPEROS4,
                shDamp, shResp, shV0, false, 1.0f,
                appPDamp, appPResp, appSDamp, appSResp, appVel,
                surfDamp, surfResp, surfLift, surfVel,
                fDamp, fResp, lerp(0.18f, 0.30f, w),
                false, 0.0f, 0.0f, 1.0f, 0.96f, 0.30f,
                false, 0.96f, 0.30f, 1.0f, 0.0f, 0.0f, 0.0f);
    }

    public static String normalizeProfile(String raw) {
        if (raw == null) {
            return PROFILE_OFF;
        }
        if (PROFILE_IOS.equals(raw)) {
            return PROFILE_IOS;
        }
        if (PROFILE_COLOROS.equals(raw) || PROFILE_SILK_ALIAS.equals(raw)) {
            return PROFILE_COLOROS;
        }
        if (PROFILE_HYPEROS4.equals(raw)) {
            return PROFILE_HYPEROS4;
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
