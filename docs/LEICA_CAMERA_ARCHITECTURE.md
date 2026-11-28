# CoreSurface Camera Pro Engine & Leica Camera Bridge Architecture

> **Engineering Standard:** 100% honest, zero gimmick, strict fail-closed hardware verification, **0 KB background daemon**, and zero writes to `/vendor/etc/camera/*` or global `ro.product.mod_device`.

## 1. Hybrid 2-Layer Architecture

CoreSurface keeps its production ZIP ultra-lightweight (~85 KB, 100% clean-room) by separating universal hardware-verified unlocks from heavy proprietary Leica APK ports:

1. **Track 1 — Universal Camera Pro Engine (`FEAT_CAMERA_PRO`, Built-in):**
   - Runs `lib/camera_probe.sh` against real `dumpsys media.camera`, SoC ISP (`snapdragon` / `mediatek` / `xring`), and stock `com.android.camera` metadata, caching an immutable per-ROM profile in `$CS_STATE_DIR/camera_caps.prop`.
   - **Strict Fail-Closed Gating:**
     - **Pro Photography Aids** (Focus Peaking, Live Histogram, Zebra Exposure Verification, Horizon Level, Pro Video) → unlocked **only** if Camera2 HAL advertises `MANUAL_SENSOR` or `HAL >= FULL`.
     - **True RAW / DNG Capture** → unlocked **only** if Camera2 HAL advertises `RAW` capability AND `HAL >= FULL`.
     - **10-bit / HDR10 Video** → unlocked **only** if Camera2 HAL advertises `DYNAMIC_RANGE_TEN_BIT` / `HLG10`.
     - **4K@60fps Video** → unlocked **only** if Camera2 stream configuration advertises `3840x2160` at 60fps.
     - **Parallel Multi-Frame Processing** → unlocked **only** on non-`Lite` tiers with RAM ≥ 5.5 GB (never forced on 4 GB devices).
     - **Safe Camera Utilities** (Shutter Sound control, Document Mode, Outdoor Viewfinder Brightness) → safe across all Xiaomi/Redmi/POCO hardware.
   - **Never-Downgrade Native Leica Passthrough:** Devices shipping factory Native Leica (`Xiaomi 13/14/15/17` series) are detected read-only and never overwritten.

2. **Track 2 — Dual-Support Leica Camera Bridge (`FEAT_LEICA_BRIDGE`, Built-in):**
   - Automatically detects whether the device has:
     - `native` — Factory Native Leica camera (safe passthrough)
     - `companion` — An installed Leica Camera Companion module (community or Mystivara Companion Pack) in `/data/adb/modules`
     - `none` — Standard non-Leica stock `MiuiCamera` (honestly reported in WebUI; Track 1 Camera Pro Engine remains active)
   - **On-Boot & On-Demand Camera Crash Inspector (0 KB Daemon):**
     - Runs at late boot (`service.sh`), during `Hot-Sync`, or via the WebUI **Camera Health Check** button.
     - If `com.android.camera` records ≥ 2 crashes while Leica Bridge or a Companion module is active, CoreSurface automatically disables `FEAT_LEICA_BRIDGE=0`, writes `disable` to the incompatible companion module, and preserves Stock Camera + Camera Pro Engine cleanly.
     - Users can also trigger a 1-tap **Camera Safe Rollback** anytime from WebUI (`webui_ctl.sh camera-rollback`).
