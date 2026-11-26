package org.mystivara.coresurface.engine;

import android.app.Application;
import android.content.Context;
import android.view.View;

import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicBoolean;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;

/**
 * Thread-safe, self-unhooking single-shot Context bootstrapper.
 *
 * Captures the first Context via Application.onCreate or View.onAttachedToWindow,
 * wires EngineConfig, TelemetryReporter, ThermalLodController, DeviceBugGuard, and
 * FolmePhysicsHook once, and immediately unhooks its own bootstrap trampolines so
 * steady-state UI rendering incurs ZERO per-view Xposed overhead.
 */
public final class ProcessBootstrap {
    private final EngineConfig config;
    private final TelemetryReporter telemetry;
    private final ThermalLodController lodController;
    private final DeviceBugGuard bugGuard;
    private final FolmePhysicsHook folmeHook;

    private final AtomicBoolean bootstrapped = new AtomicBoolean(false);
    private final CopyOnWriteArrayList<XC_MethodHook.Unhook> unhooks = new CopyOnWriteArrayList<>();

    public ProcessBootstrap(EngineConfig config, TelemetryReporter telemetry,
                            ThermalLodController lodController, DeviceBugGuard bugGuard,
                            FolmePhysicsHook folmeHook) {
        this.config = config;
        this.telemetry = telemetry;
        this.lodController = lodController;
        this.bugGuard = bugGuard;
        this.folmeHook = folmeHook;
    }

    public void install() {
        XC_MethodHook bootHook = new XC_MethodHook() {
            @Override
            protected void afterHookedMethod(MethodHookParam param) {
                if (bootstrapped.get()) {
                    return;
                }
                Context ctx = null;
                if (param.thisObject instanceof Context) {
                    ctx = (Context) param.thisObject;
                } else if (param.thisObject instanceof View) {
                    ctx = ((View) param.thisObject).getContext();
                }
                bootstrapIfNeeded(ctx);
            }
        };

        try {
            addUnhooks(XposedBridge.hookAllMethods(Application.class, "onCreate", bootHook));
        } catch (Throwable ignored) {
        }
        try {
            addUnhooks(XposedBridge.hookAllMethods(View.class, "onAttachedToWindow", bootHook));
        } catch (Throwable ignored) {
        }
    }

    public void bootstrapIfNeeded(Context ctx) {
        if (ctx == null || !bootstrapped.compareAndSet(false, true)) {
            return;
        }
        try {
            final Context appCtx = ctx.getApplicationContext() != null ? ctx.getApplicationContext() : ctx;
            config.attachContext(appCtx);
            telemetry.attachContext(appCtx);
            folmeHook.attachContext(appCtx);
            telemetry.setMotionProfile(config.getMotionProfile());
            telemetry.setLastConfig(config.getRawConfig());
            config.addListener(() -> {
                telemetry.setMotionProfile(config.getMotionProfile());
                telemetry.setLastConfig(config.getRawConfig());
            });
            // Defer Binder-backed Settings/PowerManager listener registration past cold-start Frame 0
            new android.os.Handler(android.os.Looper.getMainLooper()).post(() -> {
                try {
                    lodController.attachContext(appCtx);
                    bugGuard.attachContext(appCtx);
                } catch (Throwable ignored) {
                }
            });
        } catch (Throwable ignored) {
        } finally {
            unhookAll();
        }
    }

    private void addUnhooks(Set<XC_MethodHook.Unhook> set) {
        if (set == null) {
            return;
        }
        for (XC_MethodHook.Unhook u : set) {
            if (u != null) {
                unhooks.add(u);
            }
        }
        if (bootstrapped.get()) {
            unhookAll();
        }
    }

    private void unhookAll() {
        for (XC_MethodHook.Unhook u : unhooks) {
            try {
                u.unhook();
            } catch (Throwable ignored) {
            }
        }
        unhooks.clear();
    }
}
