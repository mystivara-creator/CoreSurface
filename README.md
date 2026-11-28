# CoreSurface v1.4.1

**CoreSurface** is a clean-room, **100% standalone pure user-space** HyperOS 3 / HyperOS 4 (and MIUI) **4-Tier Flagship Experience** module — preserving **100% original HyperOS UI**, **0 KB background daemon overhead**, and strictly zero-gimmick engineering:

- **100% Standalone Pure User-Space:** Runs cleanly through strictly non-persistent `resetprop -n` properties, fail-closed dynamic `device_features` XML bind-mounting, and 5 clean-room RRO overlays.
- **English Interactive Volume-Key Installer:** Choose your **Tier Mode** during flash with Volume Up/Down (`Auto`, `Lite`, `Balanced Pro`, `Max Flagship`).
- **Native Flagship Animations & Computility:** Unlocks HyperOS's own flagship `device_level`, `deviceLevelList`, `computility` V1 (`6/6`) & V2 (`4`), `HyperTransition v3`, `parallel_sweep`, Frame Callback Booster (`FCB`), and `launch_response_optimization` — without touching Android's 3 Developer Options window animation scales.
- **Verified Blur & Material:** Full blur + HyperOS 3 Advanced Textures v4 / HyperOS 4 Bionic Material v5 + G2 SmoothCorner with strict Never-Downgrade protection and GPU-safe gating so mid-range GPUs stay fluid.
- **FOD-Safe Non-LTPO AOD Unlock:** Unlocks **Always** & **Scheduled** AOD via XML (`is_only_support_keycode_goto=false`) + clean-room `MiuiAod` RRO without optical fingerprint fade-out white flashes.
- **Hardware-Verified Camera Pro Engine & Dual-Support Leica Bridge:** Probes real Camera2 HAL capabilities (`dumpsys media.camera`), SoC ISP (`Snapdragon` / `MediaTek` / `XRING`), and stock `com.android.camera` metadata to fail-closed unlock only genuinely supported capabilities (Pro Aids: Focus Peaking, Histogram, Zebra, Pro Video; True RAW/DNG; 4K@60 / 10-bit HDR; RAM-gated Parallel Processing) — plus a **Dual-Support Leica Camera Bridge** with an **On-Boot & On-Demand 0 KB Camera Crash Inspector** and 1-tap Safe Rollback. See [`docs/LEICA_CAMERA_ARCHITECTURE.md`](docs/LEICA_CAMERA_ARCHITECTURE.md).
- **Flagship Audio & Complete Porting Suite:** Never-Downgrade audio pipeline (Dolby/Mi Sound Scenario EQ, 10-Band Graphic EQ, Earphone Acoustic Tuning, Game Turbo Audio, Stereo & Clear Speaker, 24-bit Studio Mic) + Video Toolbox Cinema, Gallery HDR/Dolby/Local OCR, Privacy Cast, VoIP & Inner Record, Night Charge AI, Wild Boost & Dynamic Font.
- **Built-in Safety & One-Tap Diagnostics:** 2-Strike Anti-Bootloop Watchdog (auto safe-mode disable), Immutable Factory Stock Snapshot, fast Binder-safe transactional `settings` rollback, and Auto Light/Dark KSU/MMRL WebUI with collapsible **Camera Hardware Inspector** + one-tap diagnostic export (`/sdcard/Download/coresurface-diag.txt`) + `action.sh`.

Part of the **[Mystivara Ecosystem](https://mystivara-creator.github.io)** — designed as an independent sister module to **CoreFlow-Engine** and **CoreType** (**Zero Coupling**, **Zero Kernel/Sysfs Touch**, **Zero Gimmick**).

> **Leica Companion Note:** CoreSurface v1.4.1 ships the built-in **Camera Pro Engine** + **Dual-Support Leica Bridge** + **0 KB Crash Inspector**. Optional SDK/SoC-matched **Leica Companion Packs** remain separate so CoreSurface stays ~80 KB and crash-free (* currently in development).

---

## 4 Tier Modes + Native Flagship Passthrough

During installation, use **`[Vol+]` = Next Option** and **`[Vol-]` = Confirm** (or wait 10s to keep the current selection):

| Tier Mode | Target Devices | Blur & Material | Animations & Base Layer | Audio, Camera & Porting Suite |
| :--- | :--- | :--- | :--- | :---: |
| **`auto`** | Smart RAM + *Immutable Stock Snapshot*: Entry/Mid Non-Pro → `Lite`, Mid Pro/Pro+ → `Balanced Pro`, High-RAM non-flagship → `Max Flagship`, **Native Flagship (`device_level ≥ 3` + factory blur) → `Stock Passthrough`** | Matches detected class (0 overrides on native flagships) | Automatic + Never-Downgrade | Matches class (Native Leica → Passthrough) |
| **`low` (`Lite`)** | Entry & Mid-Range Non-Pro or ultra-light 60 Hz priority | **Standard Blur ON** (CC/Shade/Folder), **no Advanced Textures**, `appLaunch=0` | `device_level=2`, `v:1,c:2,g:2`, `FCB`, launch optimization ON, lightweight RRO (`SystemUI` + `ThemeManager` + `MiuiAod`) | **Flagship Audio ON** + **Camera Pro ON** (Parallel Process OFF on Lite/4GB) + **Color Expert ON** |
| **`balanced_pro` (`Balanced Pro`)** | Mid-Range Pro / Pro+ daily flagship feel | Full blur + HOS 3/4 Advanced Textures + G2 SmoothCorner | `device_level=2`, `v:1,c:2,g:3`, `computility=4/4` (V2 `3`), `HyperTransition v3`, `parallel_sweep`, `FCB`, full RRO & Video Depth | **Flagship Audio ON** + **Camera Pro ON** + **Porting Suite ON** + **Color Expert ON** |
| **`flagship` (`Max Flagship`)** | Full flagship capability suite while staying ultra-light | Full blur + HOS 3 Advanced Textures v4 / HOS 4 Bionic Material v5 + G2 SmoothCorner | `device_level=3`, `v:1,c:3,g:3`, `computility=6/6` (V2 `4`) + post-boot re-assertion, `HyperTransition v3`, `parallel_sweep`, `FCB`, full RRO & XML | **Flagship Audio ON** + **Camera Pro ON** + **Porting Suite ON** + **Color Expert ON** |

---

## Quick Installation

1. Flash `CoreSurface-v1.4.1.zip` in **KernelSU-Next** (ensure `meta-overlayfs` is installed for RRO overlays), **Magisk**, or **APatch**.
2. Choose your **Tier Mode** using **Volume Up / Volume Down** → reboot once.
3. Open **KernelSU-Next → Modules → CoreSurface → Open WebUI** (or tap **Action**) to switch Tier Modes, inspect real Camera2 hardware capabilities, toggle AOD/Audio/Camera/Porting Suite, run Hot-Sync & Verify, or export diagnostics to `/sdcard/Download/coresurface-diag.txt`.
*(Upgrading from v1.0–v1.2 automatically removes the legacy `CoreSurfaceEngine.apk` on first boot — no manual cleanup needed.)*

---

## Local Verification & Packaging

```sh
shellcheck -s sh -x customize.sh post-fs-data.sh service.sh action.sh uninstall.sh lib/*.sh scripts/*.sh tests/*.sh
node --check webroot/app.js
sh tests/run_tests.sh
sh scripts/package.sh
```
