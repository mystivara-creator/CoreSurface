# CoreSurface v1.0.0

**CoreSurface** adalah suite *user-space* HyperOS/MIUI **4-Tier Pure Experience** yang ditulis ulang sepenuhnya dari nol (*clean-room*) — **100% mempertahankan tampilan asli HyperOS**, ringan, ramah pengguna, dan bebas gimmick:

1. **Layer 1 — CoreSurface Universal Base (KernelSU-Next / Magisk / APatch / Recovery — Standalone):** Berjalan penuh bahkan tanpa LSPosed. Mencakup **Volume Up/Down Interactive Installer** (4 Mode Tier, bebas hang), **Immutable Factory Stock Snapshot** (anti salah-klasifikasi pasca-boot), tombol **Action (`action.sh`)**, properti terverifikasi non-persisten (`resetprop -n`), *Dynamic `device_features` XML Patcher* fail-closed (termasuk **Custom Color Expert** di semua mode), 5 *Clean-Room RRO Overlays*, Watchdog anti-bootloop (dengan kill-switch Layer 2), dan *Transactional Settings Rollback*.
2. **Layer 2 — CoreSurface Motion & Fix Engine (`CoreSurfaceEngine.apk`, ~38 KB, LSPosed Opsional):** Otomatis aktif bila LSPosed/Vector sudah terpasang (CoreSurface sengaja **tidak** membundle Zygisk/Vector sendiri agar tidak bentrok di `zygote`/`libart.so`). Menyediakan **60/90/120/144 Hz Continuous Refresh-Rate-Aware Folme Spring Physics** (*HyperOS 4* / *iOS · ColorOS 17 Silk*), **Self-Unhooking `ProcessBootstrap`** (0 overhead per-view pasca-startup), **Native Flagship Tier Unlock** (*Never-Downgrade*), **Surgical HyperOS 3 Toast & Recent Apps Fix** (`BlurUtils` + `MiBackgroundBlur`), **Non-LTPO AOD 10s-Cap Unlock**, **Per-Hook Circuit Breakers**, dan **Thermal-Adaptive Motion Safety**.

Dirancang sebagai *sister module* (pendamping terpisah) dari **CoreFlow-Engine** dengan prinsip **100% Original UI**, **Zero Coupling**, & **Zero Gimmick**.

---

## 4 Mode Tier + Native Flagship Passthrough (Volume Up/Down & WebUI)

Saat flash melalui KernelSU-Next / Magisk / APatch, gunakan **`[Vol+]` = Ganti Mode** dan **`[Vol-]` = Pilih** (atau diam 10 detik untuk otomatis memakai `Auto`):

| Mode Tier | Target Perangkat | Blur & Advanced Textures | Animasi & Base Layer 1 | Audio & Porting Suite |
| :--- | :--- | :--- | :--- | :---: |
| **`auto`** | Deteksi cerdas RAM + *Immutable Factory Stock Snapshot*: Entry/Mid Non-Pro → `Lite`, Mid Pro/Pro+ → `Balanced Pro`, High-RAM non-flagship → `Max Flagship`, **Native Flagship asli (`device_level ≥ 3` + blur pabrik) → `Motion-Only Passthrough`** (tuning pabrik utuh!) | Sesuai kelas terdeteksi (0 overwrite pada Flagship asli) | Otomatis + prinsip *Never-Downgrade* | Sesuai kelas (`motion_only` dilewati) |
| **`low` (`Lite`)** | Entry & Mid-Range Non-Pro (mis. Redmi Note 15 5G) atau prioritas ringan/60 Hz | **Blur Standar ON** (CC/Shade/Folder), **TANPA Advanced Textures** | `device_level=2`, `v:1,c:2,g:2`, RRO ringan (`SystemUI` + `ThemeManager` + `MiuiAod`), tanpa Video Depth / Freeform berat | **Audio Flagship ON** + **Color Expert ON** (Porting Suite OFF default) |
| **`balanced_pro` (`Balanced Pro`)** | Mid-Range Pro / Pro+ (mis. Poco X8 Pro, Redmi Note 15 Pro / Pro+ 5G) atau user Non-Pro yang ingin suite harian lengkap | Blur penuh (HOS 3 default tetap aman dari bug Toast/Recents) | `device_level=2`, `v:1,c:2,g:3`, `computility=4/4` (V2 `3`), `HyperTransition v3`, `barfollow_anim`, RRO penuh, Video Depth, Multitask & High Hz | **Audio Flagship ON** + **Flagship Porting Suite ON** + **Color Expert ON** |
| **`flagship` (`Max Flagship`)** | Enthusiast / Mid Pro+ yang ingin pembukaan kapabilitas flagship penuh | Blur penuh (HOS 3 safe default + Surgical Guard) | `device_level=3`, `v:1,c:3,g:3` (prop + `settings`), `computility=6/6` (V2 `4`) + post-boot re-assert, `HyperTransition v3`, `barfollow_anim`, `parallel_sweep`, RRO & XML penuh, Silk Folme | **Audio Flagship ON** + **Flagship Porting Suite ON** + **Color Expert ON** |

---

## Fitur Porting Flagship & Kualitas Speaker (`FEAT_FLAGSHIP_AUDIO` + `FEAT_FLAGSHIP_SUITE`)

CoreSurface bukan sekadar membuka blur, tetapi membuka **kapabilitas porting flagship nyata** (terverifikasi, 100% *user-space*, tanpa gimmick):

- **Flagship Audio & Speaker Enhancement (`FEAT_FLAGSHIP_AUDIO` — aktif di semua mode non-`motion_only`):**
  - **Speaker Output & Kejernihan:** `ro.vendor.audio.spk.stereo=true`, `ro.vendor.audio.spk.clean=true` (*Clear Speaker* + profil stereo speaker), `ro.vendor.audio.sfx.scenario=true` (*Mi Sound Scenario EQ*: Smart / Music / Video / Voice), `ro.vendor.audio.dolby.dax.support=true` (Dolby DAX), `ro.audio.spatializer_enabled=true` (Spatial Audio).
  - **Hi-Fi & Ekosistem Audio:** `ro.vendor.audio.hifi=true`, `persist.vendor.audio.hifi.int_codec=true`, `ro.vendor.audio.sfx.audiovisual=true`, `ro.vendor.audio.soundfx.usb=true`, `ro.vendor.audio.misound.bluetooth.enable=true`, `ro.vendor.audio.voice.change.support=true`.
  - **XML `device_features` Audio:** `support_dolby`, `support_hifi`, `support_sound_assist` (*Sound Assistant* multi-app volume), `support_audio_share`, `support_stereo_record`, `support_24bit_record`, `support_lhdc_offload`, `support_audio_loopback`, `support_phone_call_noise_suppression`.
- **Flagship Exclusive Porting Suite (`FEAT_FLAGSHIP_SUITE` — aktif di `Balanced Pro` & `Max Flagship`):**
  - **AI Image Engine & Video Toolbox:** `support_AI_display`, `support_super_resolution`, `support_hdr_enhance`, `support_screen_enhance_engine`, `support_truetone`, `is_support_video_tool_box`, `support_videobox_display_effect`, `support_videobox_cinema_adapt_ce` (tetap menjaga tag display/warna/touch pabrik tidak tersentuh).
  - **Game Turbo Flagship:** `support_wild_boost`, `support_wild_boost_bat_perf`, `support_displayfeature_gamemode`, `support_displayfeature_gamemode_HDR`, `support_mi_game_macro`, `support_game_gunsight`.
  - **Sistem & Produktivitas Flagship:** Dynamic Font Weight Animation (`ro.miui.ui.font.animation=enable`), Multi-Window Full-Decor (`ro.multiwin.fulldecor_support=true`), Live Photo v3 (`ro.product.camera.livephoto.support=3`), Power Modes (`persist.sys.power_mode_support=true`, `support_power_mode`, `support_power_save_new`), Launch Response Optimization (`persist.sys.launch_response_optimization.enable=true`), AI Subtitles & Voice Translation (`persist.sys.translate.state.supportAiSubtitles=true`, `persist.sys.translate.state.supportVoiceTrans=true`), App Hiding, Partial Screenshot, UI Orientation v2.

---

## Perbandingan: CoreSurface v1.0.0 vs `ukriu/HyperUnlocked`

| Aspek | `ukriu/HyperUnlocked` | **CoreSurface v1.0.0** |
| :--- | :--- | :--- |
| **Capability Suite (Blur, Anim, Computility 6/4, Audio Flagship, Porting Suite, XML, RRO)** | Pembukaan kapabilitas statis | **Setara & lengkap pada seluruh fitur nyata** (`computility=6/6`, V2 `4`, `system/deviceLevelList`, `is_only_support_keycode_goto=false`, **Audio/Speaker Flagship**, **AI Image Engine / Video Toolbox / Game Turbo Wild Boost / Dynamic Font**) + **Custom Color Expert di semua mode** + **0 properti plasebo** |
| **Keamanan Properti & Bootloop** | Menulis `system.prop` / prop persisten | **Strict `resetprop -n`** (memori saja, 0 polusi `/data/property`) + **Post-Boot Computility Re-Assertion** + **Watchdog 2-Strike Auto Safe-Mode & Engine Kill-Switch** + **Transactional Rollback** |
| **Native Flagship & Never-Downgrade** | Menimpa konfigurasi secara seragam | **Native Flagship Passthrough (`motion_only`)** + **Immutable Stock Snapshot** + proteksi *Never-Downgrade* di prop, XML, & runtime Java |
| **Fix Bug HyperOS 3 (Toast Melebar & Recent Apps Hitam)** | Belum ada perbaikan runtime | **`SurgicalBlurGuardHook`** di `com.miui.home` (`BlurUtils` + `MiBackgroundBlur`) & Toast Window Guard dengan *circuit breaker* |
| **60/90/120 Hz Flagship Motion (iOS 18 / ColorOS 17 Silk vs HyperOS 4)** | Kurva bawaan Xiaomi saja | **6-Layer Continuous Refresh-Rate-Aware Spring Engine** (terasa nyata di 60–144 Hz, beda tegas antara *Silk* `1.24×` buoyant vs *HyperOS 4* `0.90×` crisp, live tanpa reboot) + **Thermal-Adaptive Motion Safety** |
| **Non-LTPO AOD 10s-Cap Unlock ("Always" & "Scheduled")** | XML (`is_only_support_keycode_goto=false`) | **4-Layer Unlock** (XML `is_only_support_keycode_goto=false` + `is_video_screen=true` + RRO + `aod_mode_time=0` + hook `FeatureParser` & `MiuiAod`) |
| **Kontrol Pengguna & Verifikasi** | Instalasi standar | **Volume Up/Down 4-Tier Installer** + **`action.sh`** + **WebUI Ringkas** + **Stale-Boot-Proof Runtime Verifier (`BOOT_ID`)** |

---

## Fitur Live Engine (Opsional via LSPosed — Hot-Reload Tanpa Reboot)

Scope default: `System UI`, `System Launcher (MiuiHome)`, `Always-on Display`, `Settings` — dan mendukung aplikasi UI tambahan apa pun yang dicentang di LSPosed (`android`/`system_server` selalu diblokir keras demi 0% risiko bootloop):

- **Analytical Damped Harmonic Oscillator di Segala UI (`SpringPhysicsCurve` + `FolmePhysicsHook`):**
  - Menggunakan rumus fisika osilator harmonik teredam nyata ($\omega_n = 2\pi / T$, $k = \omega_n^2$, $x(t) = 1 - e^{-\zeta\omega_n t}(\cos\omega_d t + \frac{\zeta}{\sqrt{1-\zeta^2}}\sin\omega_d t)$) dengan **strict monotonic `[0, 1]` 128-point LUT** (~3 ns/frame, 0 alokasi memori per frame, 0 glitch `ArgbEvaluator`/alpha) yang beradaptasi kontinyu pada **60 / 90 / 120 / 144 Hz** via `DisplayManager.DisplayListener`.
  - **Karakteristik nyata & mudah dibedakan (termasuk di layar 60 Hz):**
    - **`silk` (iOS 18 / ColorOS 17):** Impuls awal cepat + ekor deselerasi cair yang panjang & membal lembut (`ζ = 0.78–0.82`, `response = 0.42–0.48s`, durasi transisi UI `1.24×`).
    - **`hyperos4` (HyperOS 4 Flagship):** Cambukan cepat, rapat, & responsif tanpa lamban (`ζ = 0.88–0.91`, `response = 0.30–0.35s`, durasi transisi UI `0.90×`).
  - Diterapkan seragam pada **6 lapisan animasi UI**: (1) Xiaomi Folme `EaseManager.getStyle`, (2) `miuix.animation.base.AnimConfig.setEase`, (3) `EaseManager.getInterpolator`, (4) Miui & Jetpack `SpringForce` (80% blend), (5) `ValueAnimator.setInterpolator` + duration scaling, serta (6) `ViewPropertyAnimator.setInterpolator` + duration scaling (sambil tetap menjaga kurva exit ease-in, linear, spinner/progress bar, dan animasi infinite).
- **Self-Unhooking `ProcessBootstrap` & Per-Hook Circuit Breakers (`DeviceBugGuard`):**
  - Hook bootstrap `Application.onCreate` / `View.onAttachedToWindow` langsung **melepas diri (`unhook`)** setelah `Context` pertama tertangkap sehingga 0 overhead per-view saat penggunaan normal; setiap hook dilindungi *circuit breaker* otomatis bila terjadi anomali bytecode OEM.
- **Device Logic & OS/System Bug Detector (`lib/os_bug_logic.sh` + `DeviceBugGuard`):**
  - Mendeteksi & memitigasi otomatis anomali OS/ROM nyata secara runtime (zero hardcode): `HOS3_ADVTEX_TOAST_RECENTS`, `HOS3_AOD_FULLSCREEN_CRASH`, `SDK35_ROOT_BINDER_GUARD`, `SOFT_REBOOT_STALE_XML`, `NON_LTPO_AOD_10S_CAP`, `VENDOR_BLUR_LOWRAM_THROTTLE`, `LEAKED_PERSIST_PROPS`, dan `MISSING_META_OVERLAYFS`.
- **Root-Cause HyperOS 3 Recent Apps & Toast Guard (`SurgicalBlurGuardHook`):** Mengarahkan `com.miui.home` `BlurUtils` (`isUseCompleteBlurOnDev` / `getBlurType`) & `MiBackgroundBlur` pada view Recents kembali ke wallpaper blur standar yang stabil (tanpa merusak blur Folder atau Control Center), serta membersihkan blur rusak pada jendela Toast.
- **Non-LTPO AOD Always-On Unlock (`LivingFlowAodHook` + `CoreSurfaceMiuiAod.apk`):** Menghapus batas 10 detik AOD melalui kombinasi RRO (`aod_support_10s_mode=false`, `support_aod_always_on=true`), XML AON (`is_only_support_keycode_goto=false`), `aod_mode_time=0`, dan hook gerbang kapabilitas `com.miui.aod` + `FeatureParser` (tanpa menyentuh field `mFullAodHideEase`).
- **Thermal-Adaptive Motion Safety (`ThermalLodController`):** Menggunakan `PowerManager.OnThermalStatusChangedListener` resmi Android (zero kernel/sysfs coupling) untuk menjaga 120 FPS tetap responsif saat suhu naik.

---

## Prinsip Arsitektur

- **Zero Gimmick Policy:** Fitur yang tidak terbukti bekerja nyata (seperti *Gallery Pro* XML & properti plasebo Island/AI) telah dihapus total; telemetri menggunakan `BOOT_ID` kernel agar tidak pernah memalsukan status aktif dari boot sebelumnya.
- **Zero Coupling dengan CoreFlow-Engine:** 100% mandiri di *user-space*; tidak pernah menyentuh `uclamp`, `thermal_zone`, atau `sysfs` CPU/GPU/storage.
- **Zero-Hardcode Device List:** Tidak ada daftar codename HP statis.
- **Non-Persistent & Clean Rollback:** Seluruh properti wajib `resetprop -n` (memori saja, tidak pernah membuat `system.prop` atau menulis `/data/property`), rollback otomatis untuk `settings`, dan uninstall bersih termasuk `CoreSurfaceEngine.apk`.
- **Zero Binary Blobs di Git:** Seluruh RRO Overlays (`overlays-src/`) dan `CoreSurfaceEngine.apk` (`engine-src/`) dibangun langsung dari source saat packaging/CI (mendukung persistent release keystore via `CORESURFACE_KEYSTORE`).

---

## Instalasi Singkat

1. Flash `CoreSurface-v1.0.0.zip` di **KernelSU-Next** (pastikan `meta-overlayfs` aktif untuk RRO), **Magisk**, atau **APatch** → pilih **Mode Tier** & **Profil Animasi** memakai tombol **Volume Up / Volume Down** → reboot 1×.
2. *(Opsional untuk 60/90/120 Hz Folme, Fix Recent Apps, & Non-LTPO AOD)*: Jika sudah memakai LSPosed/Vector, aktifkan **CoreSurface Engine** (otomatis terpasang & ter-update oleh `service.sh`; scope: `System UI`, `System Launcher / MiuiHome`, `Always-on Display`, `Settings`).
3. Buka **KernelSU-Next → Modules → CoreSurface → Open WebUI** (atau tekan tombol **Action** untuk sync & diagnostik instan) untuk berpindah Mode Tier atau Profil Animasi Live kapan saja.

---

## Pengujian Lokal & Packaging

```sh
shellcheck -s sh -x customize.sh post-fs-data.sh service.sh action.sh uninstall.sh lib/*.sh scripts/*.sh tests/*.sh
node --check webroot/app.js
sh tests/run_tests.sh
sh scripts/package.sh
```

---

## References / Credits

- Inspirasi konsep pembukaan kapabilitas *user-space* HyperOS dan referensi tag `device_features` merujuk secara jujur kepada **[`ukriu/HyperUnlocked`](https://github.com/ukriu/HyperUnlocked)**. Seluruh kode skrip, installer Volume Key 4-Tier, arsitektur pengaman, XML patcher fail-closed, RRO source, 60/120 Hz Folme Motion Engine, Recents/AOD Guard, verifier, WebUI ringkas, dan pengujian pada CoreSurface ditulis ulang sepenuhnya (*clean-room*) dari nol.
