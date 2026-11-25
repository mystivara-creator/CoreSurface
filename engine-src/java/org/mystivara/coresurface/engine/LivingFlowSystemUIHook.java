package org.mystivara.coresurface.engine;

/**
 * CoreSurface Pure Flagship Motion & Experience Hook for com.android.systemui.
 *
 * Preserves 100% original HyperOS visual appearance:
 * - ZERO custom glass drawables, overlays, FBO shaders, or steady-state view hooks.
 * - Unlocks Xiaomi's native flagship tier via DeviceLevelUnlockHook.
 * - Refines Xiaomi's native 60/90/120 Hz Folme & Jetpack SpringForce curves via FolmePhysicsHook.
 * - Strips broken HyperOS 3 Toast window blur via SurgicalBlurGuardHook.
 * - Uses self-unhooking ProcessBootstrap for zero steady-state view attach overhead.
 */
public final class LivingFlowSystemUIHook {
    private final ProcessBootstrap bootstrap;
    private final FolmePhysicsHook folmeHook;
    private final SurgicalBlurGuardHook blurGuard;
    private final DeviceLevelUnlockHook deviceLevelHook;

    public LivingFlowSystemUIHook(ProcessBootstrap bootstrap, FolmePhysicsHook folmeHook,
                                  SurgicalBlurGuardHook blurGuard, DeviceLevelUnlockHook deviceLevelHook) {
        this.bootstrap = bootstrap;
        this.folmeHook = folmeHook;
        this.blurGuard = blurGuard;
        this.deviceLevelHook = deviceLevelHook;
    }

    public void install(ClassLoader cl) {
        blurGuard.installWindowToastGuard(cl);
        deviceLevelHook.install(cl);
        folmeHook.install(cl);
        bootstrap.install();
    }
}
