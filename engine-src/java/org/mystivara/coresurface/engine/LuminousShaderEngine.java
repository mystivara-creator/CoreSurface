package org.mystivara.coresurface.engine;

import android.content.Context;
import android.graphics.RenderEffect;
import android.graphics.RuntimeShader;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.View;

import java.lang.ref.WeakReference;
import java.util.Iterator;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.concurrent.CopyOnWriteArraySet;

/**
 * CoreSurface Luminous Optical Glass Engine (Native Android 13-16 AGSL GPU Shader).
 *
 * Production hardening:
 * - Premultiplied-alpha accurate compositing (no white blowout on translucent glass tiles).
 * - Seam-free analytical rounded-box normals (no sign(0.0) dead line).
 * - Strict UI-thread SensorManager delivery via mainHandler (zero CalledFromWrongThreadException).
 * - Geometry bounds check (only genuine tile/card/slider/pill sizes, never tiny icons or fullscreen).
 * - Zero idle battery drain: Sensor.TYPE_GRAVITY active ONLY while a decorated view is visible.
 */
public final class LuminousShaderEngine {

    /**
     * Clean-room AGSL Optical Glass & Specular Rim Fragment Shader (SkSL compliant).
     */
    private static final String LUMINOUS_GLASS_AGSL =
            "uniform shader contents;\n"
          + "uniform float2 iResolution;\n"
          + "uniform float2 iLightPos;\n"
          + "uniform float2 iTouchPos;\n"
          + "uniform float iTouchGlow;\n"
          + "uniform float iRadius;\n"
          + "uniform float iLod;\n"
          + "\n"
          + "float sdRoundedBox(float2 p, float2 b, float r) {\n"
          + "    float2 q = abs(p) - b + float2(r, r);\n"
          + "    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0, 0.0))) - r;\n"
          + "}\n"
          + "\n"
          + "half4 main(float2 fragCoord) {\n"
          + "    float2 res = max(iResolution, float2(2.0, 2.0));\n"
          + "    float2 halfRes = res * 0.5;\n"
          + "    float2 p = fragCoord - halfRes;\n"
          + "    float r = clamp(iRadius, 6.0, min(halfRes.x, halfRes.y));\n"
          + "    float d = sdRoundedBox(p, halfRes, r);\n"
          + "    if (d > 1.5) {\n"
          + "        return contents.eval(fragCoord);\n"
          + "    }\n"
          + "\n"
          + "    // Seam-free sign (-1.0 or +1.0, never 0.0)\n"
          + "    float2 sgn = step(float2(0.0, 0.0), p) * 2.0 - float2(1.0, 1.0);\n"
          + "    float2 q = abs(p) - halfRes + float2(r, r);\n"
          + "    float2 rawN = (max(q.x, q.y) > 0.0)\n"
          + "        ? normalize(max(q, float2(0.0, 0.0)) + float2(1e-4, 1e-4)) * sgn\n"
          + "        : ((q.x > q.y) ? float2(sgn.x, 0.0) : float2(0.0, sgn.y));\n"
          + "\n"
          + "    // Bevel thickness (~14px optical glass rim)\n"
          + "    float edgeBand = clamp(1.0 - (-d / 14.0), 0.0, 1.0);\n"
          + "    float rimLine = smoothstep(0.60, 0.98, edgeBand);\n"
          + "    float2 maxUv = res - float2(1.0, 1.0);\n"
          + "\n"
          + "    half4 baseColor;\n"
          + "    if (iLod >= 0.85) {\n"
          + "        // FULL LOD: Optical bevel refraction + subtle RGB chromatic dispersion\n"
          + "        float refr = edgeBand * edgeBand * 3.6;\n"
          + "        float2 uvR = clamp(fragCoord - rawN * (refr * 1.16), float2(0.0, 0.0), maxUv);\n"
          + "        float2 uvG = clamp(fragCoord - rawN * refr, float2(0.0, 0.0), maxUv);\n"
          + "        float2 uvB = clamp(fragCoord - rawN * (refr * 0.84), float2(0.0, 0.0), maxUv);\n"
          + "        half4 cR = contents.eval(uvR);\n"
          + "        half4 cG = contents.eval(uvG);\n"
          + "        half4 cB = contents.eval(uvB);\n"
          + "        baseColor = half4(cR.r, cG.g, cB.b, cG.a);\n"
          + "    } else if (iLod >= 0.5) {\n"
          + "        // BALANCED LOD: Single-tap bevel refraction\n"
          + "        float2 uv = clamp(fragCoord - rawN * (edgeBand * 2.2), float2(0.0, 0.0), maxUv);\n"
          + "        baseColor = contents.eval(uv);\n"
          + "    } else {\n"
          + "        // ECO LOD: Zero extra texture taps (120 FPS thermal protection)\n"
          + "        baseColor = contents.eval(fragCoord);\n"
          + "    }\n"
          + "\n"
          + "    // Directional specular rim highlight (tilt + optical key light)\n"
          + "    float2 lightDir = normalize(iLightPos + float2(1e-4, 1e-4));\n"
          + "    float specAlign = pow(clamp(dot(rawN, lightDir) * 0.5 + 0.5, 0.0, 1.0), 3.0);\n"
          + "    float counterRim = pow(clamp(dot(rawN, -lightDir) * 0.5 + 0.5, 0.0, 1.0), 4.0) * 0.35;\n"
          + "    float spec = rimLine * (specAlign * 0.28 + counterRim * 0.20 + 0.04) * (0.45 + 0.55 * iLod);\n"
          + "\n"
          + "    // Interactive touch-point radial luminous bloom\n"
          + "    float touchFalloff = 0.0;\n"
          + "    if (iTouchGlow > 0.01) {\n"
          + "        float distToTouch = length(fragCoord - iTouchPos) / max(res.x, res.y);\n"
          + "        touchFalloff = exp(-distToTouch * 4.2) * iTouchGlow * 0.20;\n"
          + "    }\n"
          + "\n"
          + "    // Premultiplied-alpha safe glass specular compositing\n"
          + "    half inAlpha = clamp(baseColor.a, half(0.0), half(1.0));\n"
          + "    if (inAlpha <= half(0.01)) {\n"
          + "        return baseColor;\n"
          + "    }\n"
          + "    half addVal = half(spec + touchFalloff);\n"
          + "    half outAlpha = clamp(inAlpha + addVal * half(0.35), half(0.0), half(1.0));\n"
          + "    half3 glow = half3(addVal, addVal, addVal) * outAlpha;\n"
          + "    half3 finalRgb = min(baseColor.rgb + glow, half3(outAlpha, outAlpha, outAlpha));\n"
          + "    return half4(finalRgb, outAlpha);\n"
          + "}\n";

    private static final class ViewLuminousState {
        final WeakReference<View> viewRef;
        final RuntimeShader shader;
        float touchX;
        float touchY;
        float touchGlow;
        float radiusPx;
        boolean effectApplied;

        ViewLuminousState(View view, RuntimeShader shader, float radiusPx) {
            this.viewRef = new WeakReference<>(view);
            this.shader = shader;
            this.radiusPx = radiusPx;
        }
    }

    private final EngineConfig config;
    private final ThermalLodController lodController;
    private final TelemetryReporter telemetry;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Set<ViewLuminousState> activeStates = new CopyOnWriteArraySet<>();
    // UI-thread-only map (no View.setTag resource-id collision risk)
    private final WeakHashMap<View, ViewLuminousState> viewStateMap = new WeakHashMap<>();

    private volatile boolean shaderVerified = false;
    private volatile boolean sensorRegistered = false;
    private SensorManager sensorManager;
    private Sensor gravitySensor;

    private volatile float lightX = -0.55f;
    private volatile float lightY = -0.83f;
    private long lastSensorUpdateMs = 0L;

    private final SensorEventListener gravityListener = new SensorEventListener() {
        @Override
        public void onSensorChanged(SensorEvent event) {
            if (!config.isLuminousGlass() || !config.isLuminousTilt()) {
                unregisterSensor();
                return;
            }
            long now = System.currentTimeMillis();
            // Throttle tilt shader updates to ~30 Hz (smooth optical light shift, minimal GPU work)
            if (now - lastSensorUpdateMs < 33L) {
                return;
            }
            lastSensorUpdateMs = now;

            float gx = event.values[0] / 9.81f;
            float gy = event.values[1] / 9.81f;
            float targetX = clamp(-0.45f - gx * 0.9f, -1.0f, 1.0f);
            float targetY = clamp(-0.65f + (gy - 0.5f) * 0.8f, -1.0f, 1.0f);

            // Exponential low-pass filter so specular light glides smoothly without jitter
            lightX = lightX + (targetX - lightX) * 0.28f;
            lightY = lightY + (targetY - lightY) * 0.28f;
            refreshAllVisibleViews();
        }

        @Override
        public void onAccuracyChanged(Sensor sensor, int accuracy) {
        }
    };

    public LuminousShaderEngine(EngineConfig config, ThermalLodController lodController, TelemetryReporter telemetry) {
        this.config = config;
        this.lodController = lodController;
        this.telemetry = telemetry;
        verifyAgslSupport();
        this.lodController.addListener(this::refreshAllVisibleViews);
    }

    private void verifyAgslSupport() {
        if (Build.VERSION.SDK_INT < 33) {
            telemetry.setAgslCompiled(false);
            return;
        }
        try {
            RuntimeShader probe = new RuntimeShader(LUMINOUS_GLASS_AGSL);
            probe.setFloatUniform("iResolution", 100.0f, 100.0f);
            probe.setFloatUniform("iLightPos", -0.55f, -0.83f);
            probe.setFloatUniform("iTouchPos", 50.0f, 50.0f);
            probe.setFloatUniform("iTouchGlow", 0.0f);
            probe.setFloatUniform("iRadius", 24.0f);
            probe.setFloatUniform("iLod", 1.0f);
            shaderVerified = true;
            telemetry.setAgslCompiled(true);
        } catch (Throwable ignored) {
            shaderVerified = false;
            telemetry.setAgslCompiled(false);
        }
    }

    public boolean isSupported() {
        return Build.VERSION.SDK_INT >= 33 && shaderVerified;
    }

    public void attachSensorContext(Context context) {
        if (context == null || sensorManager != null) {
            return;
        }
        try {
            Context appCtx = context.getApplicationContext() != null ? context.getApplicationContext() : context;
            sensorManager = (SensorManager) appCtx.getSystemService(Context.SENSOR_SERVICE);
            if (sensorManager != null) {
                gravitySensor = sensorManager.getDefaultSensor(Sensor.TYPE_GRAVITY);
                if (gravitySensor == null) {
                    gravitySensor = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
                }
            }
        } catch (Throwable ignored) {
        }
    }

    public boolean isDecorated(View view) {
        return isMainThread() && view != null && viewStateMap.containsKey(view);
    }

    public void decorateView(final View view, float cornerRadiusDp) {
        if (!isSupported() || view == null || !isMainThread()) {
            return;
        }
        ViewLuminousState existing = viewStateMap.get(view);
        if (existing != null) {
            updateViewEffect(existing);
            return;
        }

        try {
            attachSensorContext(view.getContext());
            float density = view.getResources().getDisplayMetrics().density;
            float radiusPx = Math.max(12.0f, cornerRadiusDp * density);
            RuntimeShader shader = new RuntimeShader(LUMINOUS_GLASS_AGSL);
            final ViewLuminousState state = new ViewLuminousState(view, shader, radiusPx);
            viewStateMap.put(view, state);
            activeStates.add(state);
            telemetry.incLuminousViews();

            view.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or2, ob) -> {
                if ((r - l) != (or2 - ol) || (b - t) != (ob - ot)) {
                    updateViewEffect(state);
                }
            });

            view.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener() {
                @Override
                public void onViewAttachedToWindow(View v) {
                    activeStates.add(state);
                    updateViewEffect(state);
                    syncSensorRegistration();
                }

                @Override
                public void onViewDetachedFromWindow(View v) {
                    activeStates.remove(state);
                    syncSensorRegistration();
                }
            });

            updateViewEffect(state);
            syncSensorRegistration();
        } catch (Throwable ignored) {
        }
    }

    public void pulseTouchGlow(View view, float x, float y, float glowStrength) {
        if (view == null || !isSupported() || !isMainThread()) {
            return;
        }
        ViewLuminousState state = viewStateMap.get(view);
        if (state == null) {
            return;
        }
        state.touchX = x;
        state.touchY = y;
        state.touchGlow = clamp(glowStrength, 0.0f, 1.0f);
        updateViewEffect(state);
    }

    public void refreshAllVisibleViews() {
        if (!isMainThread()) {
            mainHandler.post(this::refreshAllVisibleViews);
            return;
        }
        boolean anyVisible = false;
        Iterator<ViewLuminousState> it = activeStates.iterator();
        while (it.hasNext()) {
            ViewLuminousState state = it.next();
            View v = state.viewRef.get();
            if (v == null || !v.isAttachedToWindow()) {
                activeStates.remove(state);
                continue;
            }
            if (v.isShown() && v.getWindowVisibility() == View.VISIBLE) {
                anyVisible = true;
                updateViewEffect(state);
            }
        }
        if (!anyVisible) {
            unregisterSensor();
        } else {
            syncSensorRegistration();
        }
    }

    private void updateViewEffect(ViewLuminousState state) {
        if (Build.VERSION.SDK_INT < 33 || !isMainThread()) {
            return;
        }
        View view = state.viewRef.get();
        if (view == null) {
            return;
        }
        try {
            if (!config.isLuminousGlass()) {
                clearEffectIfNeeded(view, state);
                return;
            }
            int w = view.getWidth();
            int h = view.getHeight();
            if (!isEligibleTileGeometry(view, w, h)) {
                clearEffectIfNeeded(view, state);
                return;
            }
            float lod = lodController.getEffectiveLod();
            float lx = config.isLuminousTilt() ? lightX : -0.55f;
            float ly = config.isLuminousTilt() ? lightY : -0.83f;

            state.shader.setFloatUniform("iResolution", (float) w, (float) h);
            state.shader.setFloatUniform("iLightPos", lx, ly);
            state.shader.setFloatUniform("iTouchPos", state.touchX, state.touchY);
            state.shader.setFloatUniform("iTouchGlow", state.touchGlow);
            state.shader.setFloatUniform("iRadius", Math.min(state.radiusPx, Math.min(w, h) * 0.48f));
            state.shader.setFloatUniform("iLod", lod);

            RenderEffect effect = RenderEffect.createRuntimeShaderEffect(state.shader, "contents");
            view.setRenderEffect(effect);
            state.effectApplied = true;
        } catch (Throwable ignored) {
        }
    }

    private static void clearEffectIfNeeded(View view, ViewLuminousState state) {
        if (state.effectApplied && Build.VERSION.SDK_INT >= 31) {
            view.setRenderEffect(null);
            state.effectApplied = false;
        }
    }

    /**
     * Strict geometry guard: prevents applying glass bevel refraction to tiny status icons
     * (< 44dp) or full-screen root containers (>= 98% width and >= 75% height).
     */
    private static boolean isEligibleTileGeometry(View view, int w, int h) {
        if (w <= 0 || h <= 0 || view.getResources() == null) {
            return false;
        }
        DisplayMetrics dm = view.getResources().getDisplayMetrics();
        float minW = 44.0f * dm.density;
        float minH = 34.0f * dm.density;
        if (w < minW || h < minH) {
            return false;
        }
        return !(w >= dm.widthPixels * 0.98f && h >= dm.heightPixels * 0.75f);
    }

    private void syncSensorRegistration() {
        if (!isMainThread()) {
            mainHandler.post(this::syncSensorRegistration);
            return;
        }
        if (!config.isLuminousGlass() || !config.isLuminousTilt() || sensorManager == null || gravitySensor == null) {
            unregisterSensor();
            return;
        }
        boolean hasVisible = false;
        for (ViewLuminousState s : activeStates) {
            View v = s.viewRef.get();
            if (v != null && v.isAttachedToWindow() && v.isShown() && v.getWindowVisibility() == View.VISIBLE) {
                hasVisible = true;
                break;
            }
        }
        if (hasVisible && !sensorRegistered) {
            try {
                // Deliver sensor callbacks strictly on mainHandler (UI thread safe)
                sensorRegistered = sensorManager.registerListener(
                        gravityListener, gravitySensor, SensorManager.SENSOR_DELAY_UI, mainHandler);
            } catch (Throwable ignored) {
                sensorRegistered = false;
            }
        } else if (!hasVisible) {
            unregisterSensor();
        }
    }

    private void unregisterSensor() {
        if (sensorRegistered && sensorManager != null) {
            try {
                sensorManager.unregisterListener(gravityListener);
            } catch (Throwable ignored) {
            }
            sensorRegistered = false;
        }
    }

    private static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }

    private static float clamp(float v, float min, float max) {
        return Math.max(min, Math.min(max, v));
    }
}
