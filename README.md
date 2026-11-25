# CoreSurface v1.0.0

**CoreSurface** adalah suite *user-space* HyperOS/MIUI **4-Tier Pure Experience** yang ditulis ulang sepenuhnya dari nol (*clean-room*) — **100% mempertahankan tampilan asli HyperOS**, ringan, ramah pengguna, dan bebas gimmick:

1. **Layer 1 — CoreSurface Universal Base (KernelSU-Next / Magisk / APatch / Recovery — Standalone):** Berjalan penuh bahkan tanpa LSPosed. Mencakup **Volume Up/Down Interactive Installer** (4 Mode Tier, bebas hang), **Immutable Factory Stock Snapshot** (anti salah-klasifikasi pasca-boot), tombol **Action (`action.sh`)**, properti terverifikasi non-persisten (`resetprop -n`), *Dynamic `device_features` XML Patcher* fail-closed (termasuk **Custom Color Expert** di semua mode), 5 *Clean-Room RRO Overlays*, Watchdog anti-bootloop (dengan kill-switch Layer 2), dan *Transactional Settings Rollback*.
2. **Layer 2 — CoreSurface Motion & Fix Engine (`CoreSurfaceEngine.apk`, ~38 KB, LSPosed Opsional):** Otomatis aktif bila LSPosed/Vector sudah terpasang (CoreSurface sengaja **tidak** membundle Zygisk/Vector sendiri agar tidak bentrok di `zygote`/`libart.so`). Menyediakan **60/90/120/144 Hz Continuous Refresh-Rate-Aware Folme Spring Physics** (*HyperOS 4* / *iOS · ColorOS 17 Silk*), **Self-Unhooking `ProcessBootstrap`** (0 overhead per-view pasca-startup), **Native Flagship Tier Unlock** (*Never-Downgrade*), **Surgical HyperOS 3 Toast & Recent Apps Fix** (`BlurUtils` + `MiBackgroundBlur`), **Non-LTPO AOD 10s-Cap Unlock**, **Per-Hook Circuit Breakers**, dan **Thermal-Adaptive Motion Safety**.

Dirancang sebagai *sister module* (pendamping terpisah) dari **CoreFlow-Engine** dengan prinsip **100% Original UI**, **Zero Coupling**, & **Zero Gimmick**.

---

## 4 Mode Tier + Native Flagship Passthrough (Volume Up/Down & WebUI)

Saat flash melalui KernelSU-Next / Magisk / APatch, gunakan **`[Vol+]` = Ganti Mode** dan **`[Vol-]` = Pilih** (atau diam 10 detik untuk otomatis memakai `Auto`):

| Mode Tier | Target Perangkat | Blur & Advanced Textures | Animasi & Base Layer 1 | Custom Color Expert |
| :--- | :--- | :--- | :--- | :---: |
| **`auto`** | Deteksi cerdas RAM + *Immutable Factory Stock Snapshot*: Entry/Mid Non-Pro → `Lite`, Mid Pro/Pro+ → `Balanced Pro`, High-RAM non-flagship → `Max Flagship`, **Native Flagship asli (`device_level ≥ 3` + blur pabrik) → `Motion-Only Passthrough`** (tuning pabrik utuh!) | Sesuai kelas terdeteksi (0 overwrite pada Flagship asli) | Otomatis + prinsip *Never-Downgrade* | **ON** |
| **`low` (`Lite`)** | Entry & Mid-Range Non-Pro (mis. Redmi Note 15 5G) atau prioritas ringan/60 Hz | **Blur Standar ON** (CC/Shade/Folder), **TANPA Advanced Textures** | `device_level=2`, `v:1,c:2,g:2`, RRO ringan (`SystemUI` + `ThemeManager` + `MiuiAod`), tanpa Video Depth / Freeform berat | **ON** |
| **`balanced_pro` (`Balanced Pro`)** | Mid-Range Pro / Pro+ (mis. Poco X8 Pro, Redmi Note 15 Pro / Pro+ 5G) atau user Non-Pro yang ingin suite harian lengkap | Blur penuh (HOS 3 default tetap aman dari bug Toast/Recents) | `device_level=2`, `v:1,c:2,g:3`, `HyperTransition`, RRO penuh, Video Depth, Multitask & High Hz | **ON** |
| **`flagship` (`Max Flagship`)** | Enthusiast / Mid Pro+ yang ingin pembukaan kapabilitas flagship penuh | Blur penuh (HOS 3 safe default + Surgical Guard) | `device_level=3`, `v:1,c:3,g:3`, `HyperTransition`, `parallel_sweep`, RRO & XML penuh, Silk Folme | **ON** |

---

## Perbandingan: CoreSurface v1.0.0 vs `ukriu/HyperUnlocked`

| Aspek | `ukriu/HyperUnlocked` | **CoreSurface v1.0.0** |
| :--- | :--- | :--- |
| **Capability Suite (Blur, Anim, XML, RRO, Video Depth, Multitask, Hz)** | Pembukaan kapabilitas statis | **Setara 100% pada seluruh fitur nyata** + **Custom Color Expert di semua mode** + **0 properti plasebo** |
| **Keamanan Properti & Bootloop** | Menulis `system.prop` / prop persisten | **Strict `resetprop -n`** (memori saja, 0 polusi `/data/property`) + **Watchdog 2-Strike Auto Safe-Mode & Engine Kill-Switch** + **Transactional Rollback** |
| **Native Flagship & Never-Downgrade** | Menimpa konfigurasi secara seragam | **Native Flagship Passthrough (`motion_only`)** + **Immutable Stock Snapshot** + proteksi *Never-Downgrade* di prop, XML, & runtime Java |
| **Fix Bug HyperOS 3 (Toast Melebar & Recent Apps Hitam)** | Belum ada perbaikan runtime | **`SurgicalBlurGuardHook`** di `com.miui.home` (`BlurUtils` + `MiBackgroundBlur`) & Toast Window Guard dengan *circuit breaker* |
| **60/90/120 Hz Flagship Motion (iOS / ColorOS 17 / HyperOS 4)** | Kurva bawaan Xiaomi saja | **Continuous Refresh-Rate-Aware Folme, SpringForce & Smart PathInterpolator Tuner** (live tanpa reboot) + **Thermal-Adaptive Motion Safety** |
| **Non-LTPO AOD 10s-Cap Unlock** | RRO/XML saja | **3-Layer Unlock** (RRO + XML + `aod_mode_time=0` + hook runtime `com.miui.aod`) |
| **Kontrol Pengguna & Verifikasi** | Instalasi standar | **Volume Up/Down 4-Tier Installer** + **`action.sh`** + **WebUI Ringkas** + **Stale-Boot-Proof Runtime Verifier (`BOOT_ID`)** |

---

## Fitur Live Engine (Opsional via LSPosed — Hot-Reload Tanpa Reboot)

Scope default: `System UI`, `System Launcher (MiuiHome)`, `Always-on Display`, `Settings` — dan mendukung aplikasi UI tambahan apa pun yang dicentang di LSPosed (`android`/`system_server` selalu diblokir keras demi 0% risiko bootloop):

- **Analytical Damped Harmonic Oscillator di Segala UI (`SpringPhysicsCurve` + `FolmePhysicsHook`):**
  - Menggunakan rumus fisika osilator harmonik teredam nyata ($\omega_n = 2\pi / T$, $k = \omega_n^2$, $x(t) = 1 - e^{-\zeta\omega_n t}(\cos\omega_d t + \frac{\zeta}{\sqrt{1-\zeta^2}}\sin\omega_d t)$) dengan **strict monotonic `[0, 1]` 128-point LUT** (~3 ns/frame, 0 alokasi memori per frame, 0 glitch `ArgbEvaluator`/alpha) yang beradaptasi kontinyu pada **60 / 90 / 120 / 144 Hz** via `DisplayManager.DisplayListener`.
  - Diterapkan seragam pada **4 lapisan animasi UI**: (1) Xiaomi Folme Springs (`EaseManager.getStyle`), (2) Folme Interpolators (`EaseManager.getInterpolator`), (3) Miui & Jetpack `SpringForce`, serta (4) transisi UI terbatas `ValueAnimator.setInterpolator` dengan *3-point shape sampling* untuk `PathInterpolator` (meng-upgrade ease-out/fast-out-slow-in sambil menjaga kurva exit ease-in, linear, spinner/progress bar, dan animasi infinite).
- **Self-Unhooking `ProcessBootstrap` & Per-Hook Circuit Breakers (`DeviceBugGuard`):**
  - Hook bootstrap `Application.onCreate` / `View.onAttachedToWindow` langsung **melepas diri (`unhook`)** setelah `Context` pertama tertangkap sehingga 0 overhead per-view saat penggunaan normal; setiap hook dilindungi *circuit breaker* otomatis bila terjadi anomali bytecode OEM.
- **Device Logic & OS/System Bug Detector (`lib/os_bug_logic.sh` + `DeviceBugGuard`):**
  - Mendeteksi & memitigasi otomatis anomali OS/ROM nyata secara runtime (zero hardcode): `HOS3_ADVTEX_TOAST_RECENTS`, `HOS3_AOD_FULLSCREEN_CRASH`, `SDK35_ROOT_BINDER_GUARD`, `SOFT_REBOOT_STALE_XML`, `NON_LTPO_AOD_10S_CAP`, `VENDOR_BLUR_LOWRAM_THROTTLE`, `LEAKED_PERSIST_PROPS`, dan `MISSING_META_OVERLAYFS`.
- **Root-Cause HyperOS 3 Recent Apps & Toast Guard (`SurgicalBlurGuardHook`):** Mengarahkan `com.miui.home` `BlurUtils` (`isUseCompleteBlurOnDev` / `getBlurType`) & `MiBackgroundBlur` pada view Recents kembali ke wallpaper blur standar yang stabil (tanpa merusak blur Folder atau Control Center), serta membersihkan blur rusak pada jendela Toast.
- **Non-LTPO AOD Always-On Unlock (`LivingFlowAodHook` + `CoreSurfaceMiuiAod.apk`):** Menghapus batas 10 detik AOD melalui kombinasi RRO (`aod_support_10s_mode=false`, `support_aod_always_on=true`), XML AON, `aod_mode_time=0`, dan hook gerbang kapabilitas `com.miui.aod` (tanpa menyentuh field `mFullAodHideEase`).
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
