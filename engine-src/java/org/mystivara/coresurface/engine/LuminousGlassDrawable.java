package org.mystivara.coresurface.engine;

import android.animation.ValueAnimator;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorFilter;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.RadialGradient;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.drawable.Drawable;
import android.view.animation.DecelerateInterpolator;

/**
 * CoreSurface Zero-FBO Luminous Optical Glass Drawable (120 FPS HWUI DisplayList).
 *
 * Replaces heavy multi-pass RenderEffect FBO layers (which caused severe Control Center lag)
 * with a batched hardware-accelerated Canvas overlay drawn directly onto target tiles/sliders:
 * - Crisp directional top-left -> bottom-right optical glass specular bevel border
 * - Subtle inner top-edge luminous sheen crescent (FULL LOD)
 * - Touch-point radial luminous ripple ONLY while actively pressed (0% idle redraws)
 */
public final class LuminousGlassDrawable extends Drawable {
    private final float cornerRadiusPx;
    private final float strokeWidthPx;

    private final Paint rimPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint sheenPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint touchPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF boundsF = new RectF();
    private final RectF rimF = new RectF();

    private boolean enabled = true;
    private float lod = ThermalLodController.LOD_FULL;
    private float touchX = 0.0f;
    private float touchY = 0.0f;
    private float touchAlpha = 0.0f;
    private ValueAnimator touchFadeAnimator;
    private int lastW = -1;
    private int lastH = -1;
    private float lastLod = -1.0f;

    public LuminousGlassDrawable(float cornerRadiusPx, float density) {
        this.cornerRadiusPx = cornerRadiusPx;
        this.strokeWidthPx = Math.max(2.0f, 1.45f * density);
        rimPaint.setStyle(Paint.Style.STROKE);
        rimPaint.setStrokeWidth(strokeWidthPx);
        sheenPaint.setStyle(Paint.Style.FILL);
        touchPaint.setStyle(Paint.Style.FILL);
    }

    public void setRenderState(boolean enabled, float lod) {
        boolean changed = (this.enabled != enabled) || (Math.abs(this.lod - lod) > 0.05f);
        this.enabled = enabled;
        this.lod = lod;
        if (changed) {
            lastLod = -1.0f;
            rebuildShadersIfNeeded();
            invalidateSelf();
        }
    }

    public void setTouchHighlight(float x, float y, float alpha) {
        if (!enabled || lod <= ThermalLodController.LOD_ECO + 0.05f) {
            return;
        }
        cancelFade();
        this.touchX = x;
        this.touchY = y;
        this.touchAlpha = Math.max(0.0f, Math.min(1.0f, alpha));
        invalidateSelf();
    }

    public void fadeOutTouchHighlight() {
        if (touchAlpha <= 0.01f) {
            return;
        }
        cancelFade();
        final float start = touchAlpha;
        touchFadeAnimator = ValueAnimator.ofFloat(start, 0.0f);
        touchFadeAnimator.setDuration(220L);
        touchFadeAnimator.setInterpolator(new DecelerateInterpolator());
        touchFadeAnimator.addUpdateListener(anim -> {
            touchAlpha = (Float) anim.getAnimatedValue();
            invalidateSelf();
        });
        touchFadeAnimator.start();
    }

    private void cancelFade() {
        if (touchFadeAnimator != null) {
            touchFadeAnimator.cancel();
            touchFadeAnimator = null;
        }
    }

    @Override
    protected void onBoundsChange(Rect bounds) {
        super.onBoundsChange(bounds);
        boundsF.set(bounds);
        float halfStroke = strokeWidthPx * 0.5f;
        rimF.set(bounds.left + halfStroke, bounds.top + halfStroke,
                bounds.right - halfStroke, bounds.bottom - halfStroke);
        rebuildShadersIfNeeded();
    }

    private void rebuildShadersIfNeeded() {
        int w = (int) boundsF.width();
        int h = (int) boundsF.height();
        if (w <= 4 || h <= 4) {
            return;
        }
        if (w == lastW && h == lastH && Math.abs(lod - lastLod) < 0.05f) {
            return;
        }
        lastW = w;
        lastH = h;
        lastLod = lod;

        // Directional optical specular glass border (unmistakably visible in Dark & Light modes)
        int topLeftCol = lod >= 0.85f
                ? Color.argb(150, 255, 255, 255)
                : (lod >= 0.5f ? Color.argb(118, 245, 250, 255) : Color.argb(82, 235, 245, 255));
        int midCol = Color.argb(38, 210, 232, 255);
        int bottomRightCol = lod >= 0.85f
                ? Color.argb(105, 224, 242, 255)
                : Color.argb(66, 220, 238, 255);

        rimPaint.setShader(new LinearGradient(
                rimF.left, rimF.top, rimF.right, rimF.bottom,
                new int[] { topLeftCol, midCol, bottomRightCol },
                new float[] { 0.0f, 0.52f, 1.0f },
                Shader.TileMode.CLAMP));

        // Subtle luminous top glass sheen crescent (FULL LOD only)
        if (lod >= 0.85f) {
            sheenPaint.setShader(new LinearGradient(
                    boundsF.left, boundsF.top, boundsF.left, boundsF.top + boundsF.height() * 0.55f,
                    new int[] { Color.argb(46, 255, 255, 255), Color.argb(10, 230, 244, 255), Color.TRANSPARENT },
                    new float[] { 0.0f, 0.45f, 1.0f },
                    Shader.TileMode.CLAMP));
        } else {
            sheenPaint.setShader(null);
        }
    }

    @Override
    public void draw(Canvas canvas) {
        if (!enabled) {
            return;
        }
        float w = boundsF.width();
        float h = boundsF.height();
        if (w <= 4.0f || h <= 4.0f) {
            return;
        }
        rebuildShadersIfNeeded();

        float r = Math.min(cornerRadiusPx, Math.min(w, h) * 0.48f);

        // 1. Inner optical top glass sheen (FULL LOD)
        if (lod >= 0.85f && sheenPaint.getShader() != null) {
            canvas.drawRoundRect(boundsF, r, r, sheenPaint);
        }

        // 2. Interactive touch-point radial luminous glow (active touch only)
        if (touchAlpha > 0.01f && lod >= 0.5f) {
            float glowR = Math.max(w, h) * 0.65f;
            int centerAlpha = Math.round(touchAlpha * 76.0f);
            touchPaint.setShader(new RadialGradient(
                    touchX, touchY, Math.max(8.0f, glowR),
                    Color.argb(centerAlpha, 255, 255, 255),
                    Color.TRANSPARENT,
                    Shader.TileMode.CLAMP));
            canvas.drawRoundRect(boundsF, r, r, touchPaint);
        }

        // 3. Crisp optical specular glass bevel border
        canvas.drawRoundRect(rimF, r, r, rimPaint);
    }

    @Override
    public void setAlpha(int alpha) {
        rimPaint.setAlpha(alpha);
    }

    @Override
    public void setColorFilter(ColorFilter colorFilter) {
        rimPaint.setColorFilter(colorFilter);
    }

    @SuppressWarnings("deprecation")
    @Override
    public int getOpacity() {
        return PixelFormat.TRANSLUCENT;
    }
}
