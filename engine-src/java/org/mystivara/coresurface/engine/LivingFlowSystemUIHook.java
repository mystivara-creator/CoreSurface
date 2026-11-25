package org.mystivara.coresurface.engine;

/**
 * CoreSurface Pure Flagship Motion & Experience Hook for com.android.systemui.
 *
 * Preserves 100% original HyperOS visual appearance while driving real transitions with
 * CoreSurface's own analytical physics engine (ZERO system_server hooks):
 * - Unlocks Xiaomi's native flagship tier via DeviceLevelUnlockHook.
 * - Drives Android 14–16 WMShell window transitions via ShellTransitionPhysicsEngine.
 * - Drives interruptible Control Center & QS choreography via SystemUIChoreographyHook.
 * - Calibrates native Folme/SpringForce springs via FolmePhysicsHook.
 * - Strips broken HyperOS 3 Toast window blur via SurgicalBlurGuardHook.
 */
public final class LivingFlowSystemUIHook {
    private final ProcessBootstrap bootstrap;
    private final FolmePhysicsHook folmeHook;
    private final SurgicalBlurGuardHook blurGuard;
    private final DeviceLevelUnlockHook deviceLevelHook;
    private final ShellTransitionPhysicsEngine shellEngine;
    private final SystemUIChoreographyHook sysUiChoreo;

    public LivingFlowSystemUIHook(ProcessBootstrap bootstrap, FolmePhysicsHook folmeHook,
                                  SurgicalBlurGuardHook blurGuard, DeviceLevelUnlockHook deviceLevelHook,
                                  ShellTransitionPhysicsEngine shellEngine,
                                  SystemUIChoreographyHook sysUiChoreo) {
        this.bootstrap = bootstrap;
        this.folmeHook = folmeHook;
        this.blurGuard = blurGuard;
        this.deviceLevelHook = deviceLevelHook;
        this.shellEngine = shellEngine;
        this.sysUiChoreo = sysUiChoreo;
    }

    public void install(ClassLoader cl) {
        blurGuard.installWindowToastGuard(cl);
        deviceLevelHook.install(cl);
        folmeHook.install(cl);
        shellEngine.install(cl);
        sysUiChoreo.install(cl);
        bootstrap.install();
    }
}
