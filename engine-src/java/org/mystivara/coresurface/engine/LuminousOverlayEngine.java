package org.mystivara.coresurface.engine;

import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.View;
import android.view.ViewParent;

import java.lang.ref.WeakReference;
import java.util.Iterator;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.concurrent.CopyOnWriteArraySet;

/**
 * CoreSurface Zero-FBO Luminous Optical Glass Manager.
 *
 * Key performance guarantees (eliminating the Control Center lag from v1 FBO shaders):
 * - ZERO RenderEffect / ZERO offscreen GPU FBO textures.
 * - ZERO Sensor.TYPE_GRAVITY 30Hz redraw loops.
 * - Strict ancestor deduplication: never decorates child views inside an already-decorated tile.
 * - Strict cap (MAX_DECORATED = 24) so only genuine top-level tiles, sliders, and cards are enhanced.
 * - Instant zero-reboot toggle via debug.coresurface.cfg SystemProperties IPC.
 */
public final class LuminousOverlayEngine {
    private static final int MAX_DECORATED = 24;

    private static final class Entry {
        final WeakReference<View> viewRef;
        final LuminousGlassDrawable drawable;
        boolean attachedToOverlay;

        Entry(View view, LuminousGlassDrawable drawable) {
            this.viewRef = new WeakReference<>(view);
            this.drawable = drawable;
        }
    }

    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final TelemetryReporter telemetry;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Set<Entry> activeEntries = new CopyOnWriteArraySet<>();
    private final WeakHashMap<View, Entry> viewMap = new WeakHashMap<>();

    public LuminousOverlayEngine(EngineConfig config, ThermalLodController lodController, TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.telemetry = telemetry;
        this.telemetry.setLuminousReady(true);
        this.lodController.addListener(this::refreshAll);
        this.config.addListener(this::refreshAll);
    }

    public boolean isDecorated(View view) {
        return isMainThread() && view != null && viewMap.containsKey(view);
    }

    public void decorateView(final View view, float cornerRadiusDp) {
        if (view == null || !isMainThread()) {
            return;
        }
        Entry existing = viewMap.get(view);
        if (existing != null) {
            syncEntry(existing, view);
            return;
        }

        // Strict ancestor deduplication: never decorate nested subviews of a tile
        if (hasDecoratedAncestor(view)) {
            return;
        }

        pruneDetached();
        if (activeEntries.size() >= MAX_DECORATED) {
            return;
        }

        try {
            float density = view.getResources().getDisplayMetrics().density;
            float radiusPx = Math.max(14.0f, cornerRadiusDp * density);
            LuminousGlassDrawable drawable = new LuminousGlassDrawable(radiusPx, density);
            final Entry entry = new Entry(view, drawable);
            viewMap.put(view, entry);
            activeEntries.add(entry);

            view.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or2, ob) -> {
                if ((r - l) != (or2 - ol) || (b - t) != (ob - ot)) {
                    syncEntry(entry, v);
                }
            });

            view.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener() {
                @Override
                public void onViewAttachedToWindow(View v) {
                    activeEntries.add(entry);
                    syncEntry(entry, v);
                    telemetry.setLuminousViewCount(activeEntries.size());
                }

                @Override
                public void onViewDetachedFromWindow(View v) {
                    detachDrawable(entry, v);
                    activeEntries.remove(entry);
                    telemetry.setLuminousViewCount(activeEntries.size());
                }
            });

            syncEntry(entry, view);
            telemetry.setLuminousViewCount(activeEntries.size());
        } catch (Throwable ignored) {
        }
    }

    public void onTileTouchDownOrMove(View view, float x, float y, float alpha) {
        if (view == null || !isMainThread()) {
            return;
        }
        if (!config.isLuminousGlass() || !config.isLuminousTouch()) {
            return;
        }
        Entry entry = viewMap.get(view);
        if (entry != null && entry.attachedToOverlay) {
            entry.drawable.setTouchHighlight(x, y, alpha);
        }
    }

    public void onTileTouchUp(View view) {
        if (view == null || !isMainThread()) {
            return;
        }
        Entry entry = viewMap.get(view);
        if (entry != null && entry.attachedToOverlay) {
            entry.drawable.fadeOutTouchHighlight();
        }
    }

    public void refreshAll() {
        if (!isMainThread()) {
            mainHandler.post(this::refreshAll);
            return;
        }
        pruneDetached();
        for (Entry entry : activeEntries) {
            View v = entry.viewRef.get();
            if (v != null) {
                syncEntry(entry, v);
            }
        }
        telemetry.setLuminousViewCount(activeEntries.size());
    }

    private void syncEntry(Entry entry, View view) {
        try {
            boolean on = config.isLuminousGlass();
            int w = view.getWidth();
            int h = view.getHeight();
            if (!on || !isEligibleTileGeometry(view, w, h)) {
                detachDrawable(entry, view);
                entry.drawable.setRenderState(false, lodController.getEffectiveLod());
                return;
            }
            entry.drawable.setBounds(0, 0, w, h);
            entry.drawable.setRenderState(true, lodController.getEffectiveLod());
            if (!entry.attachedToOverlay) {
                view.getOverlay().add(entry.drawable);
                entry.attachedToOverlay = true;
            }
        } catch (Throwable ignored) {
        }
    }

    private static void detachDrawable(Entry entry, View view) {
        if (entry.attachedToOverlay && view != null) {
            try {
                view.getOverlay().remove(entry.drawable);
            } catch (Throwable ignored) {
            }
            entry.attachedToOverlay = false;
        }
    }

    private boolean hasDecoratedAncestor(View view) {
        ViewParent p = view.getParent();
        int hops = 0;
        while (p instanceof View && hops < 8) {
            if (viewMap.containsKey((View) p)) {
                return true;
            }
            p = p.getParent();
            hops++;
        }
        return false;
    }

    private void pruneDetached() {
        Iterator<Entry> it = activeEntries.iterator();
        while (it.hasNext()) {
            Entry e = it.next();
            View v = e.viewRef.get();
            if (v == null || !v.isAttachedToWindow()) {
                activeEntries.remove(e);
            }
        }
    }

    private static boolean isEligibleTileGeometry(View view, int w, int h) {
        if (w <= 0 || h <= 0 || view.getResources() == null) {
            return false;
        }
        DisplayMetrics dm = view.getResources().getDisplayMetrics();
        float minW = 52.0f * dm.density;
        float minH = 42.0f * dm.density;
        if (w < minW || h < minH) {
            return false;
        }
        return !(w >= dm.widthPixels * 0.96f && h >= dm.heightPixels * 0.55f);
    }

    private static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }
}
