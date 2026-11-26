# CoreSurface v1.3.0

**CoreSurface** is a clean-room, **100% pure user-space** HyperOS 3 / HyperOS 4 (and MIUI) **4-Tier Flagship Experience** suite — preserving **100% original HyperOS UI** (including 100% stock Lock Screen → Home Screen), ultra-lightweight even on **Max Flagship**, and strictly zero-gimmick:

1. **Layer 1 — CoreSurface Universal Base (KernelSU-Next / Magisk / APatch / Recovery — Standalone):** Runs fully even without LSPosed. Includes an English **Volume Up/Down Interactive Installer** (4 Tier Modes + 4 Motion Profiles), **Immutable Factory Stock Snapshot**, **Action button (`action.sh`)**, strictly non-persistent `resetprop -n` properties (HyperOS 3 Advanced Textures v4 & HyperOS 4 Bionic Material v5 with Never-Downgrade), fail-closed **Dynamic `device_features` XML Patcher** (Custom Color Expert, Flagship Audio & Speaker, Complete Flagship Porting Suite, FOD-safe Non-LTPO AOD), 5 clean-room RRO overlays with SELinux `system_file` labeling, anti-bootloop 2-Strike Watchdog, and fast Binder-safe transactional `settings` rollback.
2. **Layer 2 — CoreSurface True Physics & Guard Engine (`CoreSurfaceEngine.apk`, ~50 KB, Optional LSPosed):** Zero-allocation, lock-free, zero `system_server` hooks, 0% idle overhead, and **persistent signing** so LSPosed enabled state & scopes survive every update automatically:
   - **Closed-Form Analytical Spring ODE (`CoreSpringSolver`):** Exact underdamped / critically-damped / overdamped solver driving the animations you interact with most — **App Open/Close (`RectFSpringAnim`)**, **Control Center & Folders (`Folme` + `CoreSurfaceChoreographer`)**, and **Page/Activity Transitions (`ShellTransitionPhysicsEngine`)** — without ever touching Android's 3 Developer Options window animation scales, while keeping Lock Screen → Home Screen 100% original HyperOS.
   - **4 Distinct Live Profiles (0 Reboot via zero-Binder `debug.coresurface.cfg`):** `Stock Flagship` (100% native Xiaomi Folme), `Snappy` (ultra-fast crisp ~220ms), `Fluid` (heavy silky cushioned glide ~560ms), and `Bouncy` (genuine elastic overshoot).
   - **Surgical Blur & FOD-Safe AOD Guards:** Prevents HyperOS 3 bloated Toasts, black Recent Apps, and solid black **-1 Screen (App Vault)** backdrops (`com.mi.android.globalminusscreen` / `com.miui.personalassistant`), while keeping Non-LTPO optical fingerprint AOD completely free of white flash regressions.

Designed as an independent sister module to **CoreFlow-Engine** (**Zero Coupling**, **Zero Kernel/Sysfs Touch**, **Zero Gimmick**).

---

## 4 Tier Modes + Native Flagship Passthrough

During installation, use **`[Vol+]` = Next Option** and **`[Vol-]` = Confirm** (or wait 10s to keep the current selection):

| Tier Mode | Target Devices | Blur & Material | Base Layer 1 & Motion | Audio & Porting Suite |
| :--- | :--- | :--- | :--- | :---: |
| **`auto`** | Smart RAM + *Immutable Stock Snapshot*: Entry/Mid Non-Pro → `Lite`, Mid Pro/Pro+ → `Balanced Pro`, High-RAM non-flagship → `Max Flagship`, **Native Flagship (`device_level ≥ 3` + factory blur) → `Motion-Only Passthrough`** | Matches detected class (0 overrides on native flagships) | Automatic + Never-Downgrade | Matches class (`motion_only` skipped) |
| **`low` (`Lite`)** | Entry & Mid-Range Non-Pro or ultra-light 60 Hz priority | **Standard Blur ON** (CC/Shade/Folder), **no Advanced Textures**, `appLaunch=0` | `device_level=2`, `v:1,c:2,g:2`, lightweight RRO (`SystemUI` + `ThemeManager` + `MiuiAod`), launch optimization ON | **Flagship Audio ON** + **Color Expert ON** (Porting Suite OFF by default) |
| **`balanced_pro` (`Balanced Pro`)** | Mid-Range Pro / Pro+ daily flagship feel | Full blur + HOS 3/4 Advanced Textures + G2 SmoothCorner | `device_level=2`, `v:1,c:2,g:3`, `computility=4/4` (V2 `3`), `HyperTransition v3`, full RRO & Video Depth | **Flagship Audio ON** + **Porting Suite ON** + **Color Expert ON** |
| **`flagship` (`Max Flagship`)** | Full flagship capability suite while staying ultra-light | Full blur + HOS 3 Advanced Textures v4 / HOS 4 Bionic Material v5 + Surgical Guard | `device_level=3`, `v:1,c:3,g:3`, `computility=6/6` (V2 `4`) + post-boot re-assertion, `HyperTransition v3`, `parallel_sweep`, full RRO & XML | **Flagship Audio ON** + **Porting Suite ON** + **Color Expert ON** |

---

## Live Engine Features (Optional via LSPosed — Zero Reboot)

Recommended scope (auto-pinned at the top of LSPosed via dual `xposedscope` + `META-INF/xposed/scope.list`):
- `com.android.systemui` (System UI / WMShell / Control Center)
- `com.miui.home` / `com.mi.android.globallauncher` (HyperOS / POCO Launcher)
- `com.mi.android.globalminusscreen` / `com.miui.personalassistant` (-1 Screen / App Vault)
- `com.miui.aod` (Non-LTPO Always-on Display)
- `com.android.settings` (Settings & universal UI spring curves)

`android` / `system_server` are hard-blocked for **0% bootloop risk**.

- **True Physics Engine (`CoreSpringSolver` + `MotionProfileSpec` — Zero Window-Scale Hacks):**
  - **`0` (Stock Flagship):** 100% pass-through native unlocked Xiaomi Folme.
  - **`snappy` (Snappy):** Ultra-fast, crisp, high-stiffness takeoff (~220ms settle) across App Open/Close, Control Center & Page Transitions.
  - **`fluid` (Fluid):** Heavy, liquid, cushioned glide (~560ms smooth deceleration tail, zero bounce).
  - **`bouncy` (Bouncy):** Genuine under-damped elastic spring (`ζ ≈ 0.66`, visible ~7% overshoot & rebound) on App Open/Close, Control Center, Folders & Page Transitions.
  - *(Legacy profile names `coloros`/`silk` → `snappy`, `hyperos4` → `fluid`, `ios` → `bouncy` are seamlessly mapped on upgrade.)*
- **Persistent In-Place Updates:** CI builds reuse a persistent signing keystore (`CORESURFACE_KEYSTORE_B64` secret or cached CI keystore) and upgrade via `pm install -r -d`, preserving LSPosed enabled status and scopes across updates.
- **FOD-Safe Non-LTPO AOD Unlock:** Unlocks **Always** & **Scheduled** AOD via XML (`is_only_support_keycode_goto=false`) + RRO + `LivingFlowAodHook` without triggering optical fingerprint ring fade-out white blinks.
- **Thermal-Adaptive Motion Safety (`ThermalLodController`):** Uses official Android `PowerManager.OnThermalStatusChangedListener` (zero kernel/sysfs coupling) to keep frame pacing smooth under heat.

---

## Quick Installation

1. Flash `CoreSurface-v1.3.0.zip` in **KernelSU-Next** (ensure `meta-overlayfs` is installed for RRO overlays), **Magisk**, or **APatch** → choose **Tier Mode** & **Motion Profile** with **Volume Up / Volume Down** → reboot once.
2. *(Optional for Live Physics, Toast/Recents/-1 Screen Guard & Non-LTPO AOD)*: Enable **CoreSurface Engine** once in **LSPosed** (all recommended apps appear pinned at the top; future updates stay enabled automatically).
3. Open **KernelSU-Next → Modules → CoreSurface → Open WebUI** (or tap **Action**) to switch Tier Modes or Live Motion Profiles anytime.

---

## Local Verification & Packaging

```sh
shellcheck -s sh -x customize.sh post-fs-data.sh service.sh action.sh uninstall.sh lib/*.sh scripts/*.sh tests/*.sh
node --check webroot/app.js
sh tests/run_tests.sh
sh scripts/package.sh
```

---

## References / Credits

- Concept inspiration for HyperOS user-space capability unlocks and `device_features` tag references acknowledges **[`ukriu/HyperUnlocked`](https://github.com/ukriu/HyperUnlocked)**. All scripts, the 4-Tier Volume-Key installer, safety Watchdog, fail-closed XML patcher, clean-room RRO overlays, closed-form `CoreSpringSolver` motion engine, surgical blur/AOD guards, verifier, WebUI, and test suite in CoreSurface are written clean-room from scratch.
