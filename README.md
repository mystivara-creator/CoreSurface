# CoreSurface v1.0.0

**CoreSurface** adalah suite *user-space* HyperOS/MIUI **Pure Flagship Motion & Experience** yang ditulis ulang sepenuhnya dari nol (*clean-room*) — **mempertahankan 100% tampilan asli HyperOS** tanpa mengubah gaya visual, menggabungkan:
1. **Layer 1 — CoreSurface KernelSU-Next / Magisk Base:** Pondasi properti terverifikasi non-persisten (`resetprop -n`), *Dynamic `device_features` XML Patcher* fail-closed (aman soft-reboot), 5 *Clean-Room RRO Overlays*, Watchdog anti-bootloop, dan *Transactional Settings Rollback*.
2. **Layer 2 — CoreSurface Flagship Motion Engine (`CoreSurfaceEngine.apk`, ~29 KB, LSPosed):** Mesin runtime Java ringan yang membuka **Native HyperOS Flagship Tier** (`DeviceLevel` / `DeviceConfig` / `CpuLevel` / `GpuLevel`) dan menyelaraskan fisika pegas native 120 Hz (**`miuix.animation.EaseManager` & `SpringForce`**) menjadi profil **HyperOS 4 Flagship** atau **iOS / ColorOS 17 Silk Fluid** — dengan hot-reload instan bebas Binder via `debug.coresurface.cfg` (**tanpa reboot**), **Surgical HyperOS 3 Toast & Recents Guard**, serta **Thermal-Adaptive Motion Safety**.

Dirancang sebagai *sister module* (pendamping terpisah) dari **CoreFlow-Engine** dengan prinsip **100% Original UI**, **Zero Coupling**, & **Zero Gimmick**.

---

## Prinsip Arsitektur (Original UI & Anti-Gimmick)

- **100% Original HyperOS Visuals:** Tidak menyuntikkan overlay kaca kustom, tidak ada shader FBO berat, tidak ada hook `dispatchTouchEvent`, dan tidak pernah menimpa animator Folme secara eksternal — 0 lag di Control Center dan 0 bentrok animasi Launcher.
- **Zero Gimmick Policy:** Seluruh properti plasebo yang tidak dibaca binary ROM (seperti flag palsu Island/AI/AOD) telah dihapus total. Setiap lencana `Verified Active` di WebUI membutuhkan bukti runtime nyata (`getprop`, `/proc/mounts`, `cmd overlay list`, atau telemetri proses live `NATIVE_GATES`, `FOLME_HOOKS`, `SPRINGS_TUNED` dari `SystemUI`/`MiuiHome`/`MiuiAod`).
- **Zero Coupling dengan CoreFlow-Engine:** 100% mandiri di *user-space*. CoreSurface **tidak pernah** menyentuh `uclamp`, `thermal_zone`, `sysfs` CPU/GPU/storage, atau parameter kernel/scheduler. *Thermal-Adaptive Motion Safety* memakai API resmi Android `PowerManager.OnThermalStatusChangedListener`.
- **Zero-Hardcode Device List:** Tidak pernah menulis codename HP secara statis. Semua deteksi menggunakan runtime `ro.mi.os.version.name`, `ro.miui.ui.version.name`, `ro.build.version.sdk`, `ro.product.device`, dan `/proc/meminfo`.
- **Non-Persistent & Clean Rollback:** Seluruh properti wajib menggunakan **`resetprop -n`** (memori saja, tidak pernah menghasilkan `system.prop` atau menulis `/data/property`), dan semua perubahan `settings` dibackup otomatis untuk rollback bersih.
- **Zero Binary Blobs di Git:** Seluruh RRO Overlays (`overlays-src/`) dan `CoreSurfaceEngine.apk` (`engine-src/`) dikompilasi dan ditandatangani langsung dari source saat packaging/CI.

---

## Fitur Live Motion Engine (LSPosed — Hot-Reload Instan Tanpa Reboot via `debug.coresurface.cfg`)

| Kunci Fitur | Cakupan Nyata (Zero Gimmick, 120 Hz Native) | Default | Catatan |
| :--- | :--- | :---: | :--- |
| `FEAT_MOTION_PROFILE` | **Folme & SpringForce Motion Profile:** menyelaraskan `miuix.animation.utils.EaseManager` & `SpringForce` menjadi kurva **HyperOS 4** (`hyperos4`), **iOS / ColorOS 17 Silk Fluid** (`silk`), atau **Stock** (`0`) | `hyperos4` | Mengubah kurva pegas bawaan Xiaomi secara native (0 bentrok animator, 0 perubahan tampilan visual). |
| `FEAT_NATIVE_TIER` | **Native HyperOS Flagship Tier Unlock:** membuka gerbang `DeviceLevelUtils` / `DeviceConfig` / `CpuLevelUtils` / `GpuLevelUtils` / `DeviceUtils` bawaan Xiaomi di `SystemUI`, `MiuiHome`, & `MiuiAod` | `auto` (ON) | Menjalankan seluruh animasi flagship native (Lockscreen → Home, App Open/Close, Control Center) secara mulus. |
| `FEAT_SURGICAL_GUARD` | **HyperOS 3 Surgical Toast & Recents Guard:** memblokir blur rusak pada jendela Toast pop-up & mencegah scrim hitam pekat di Recent Apps | `auto` (ON) | Perbaikan bug murni tanpa mengubah tampilan UI; tetap aman meski *Advanced textures* dinyalakan. |
| `FEAT_THERMAL_LOD` | **Thermal-Adaptive Motion Safety:** memantau `PowerManager` thermal status resmi untuk mengetatkan kurva pegas (`FULL → BALANCED → ECO`) saat suhu naik | `auto` (ON) | Menjaga 120 FPS tetap responsif saat perangkat hangat/gaming tanpa menyentuh kernel. |

---

## Fitur Early-Boot Base (`/data/adb/coresurface/config.prop` & WebUI)

| Kunci Fitur | Cakupan | Beban Hardware | Default `< 6 GB` | Default `6–7 GB` | Default `>= 8 GB` |
| :--- | :--- | :---: | :---: | :---: | :---: |
| `FEAT_BLUR` | SurfaceFlinger & HyperOS CC/Shade/Folder/Launcher Blur (`disable_window_blurs=0`; di HOS 3+ menjaga default *Advanced textures* OFF agar aman) | **High GPU/RAM** | OFF (`auto`) | ON (`auto`) | ON (`auto`) |
| `FEAT_ANIMATIONS` | `HyperTransition`, `parallel_sweep`, `debug.sysui.use_control_center=1`, & `deviceLevelList` dinamis | **Medium RAM** | ON (Lvl 2) | ON (Lvl 2+) | ON (Lvl 3) |
| `FEAT_XML_PATCHER` | Dynamic `device_features` XML Patcher (add-only, non-destruktif, aman soft-reboot, SELinux `chcon --reference`) | **Low Load** | ON (`auto`) | ON (`auto`) | ON (`auto`) |
| `FEAT_RRO_OVERLAYS` | 5 Clean-Room RRO APKs (`SystemUI`, `SystemUI Lite Blur`, `ThemeManager`, `MiWallpaper`, `MiuiAod`) | **Medium GPU** | OFF (`auto`) | ON (`auto`) | ON (`auto`) |
| `FEAT_VIDEO_DEPTH` | Lockscreen Video Depth (`enable_video_depth` zero-byte marker) | **Low Load** | OFF (`auto`) | ON (`auto`) | ON (`auto`) |
| `FEAT_MULTITASK` | Relaksasi `low_ram` & ambang GB, Freeform (`max_count=4`), One-Handed Mode, Partial Screenshot | **Medium RAM** | OFF (`auto`) | OFF (`auto`) | ON (`auto`) |
| `FEAT_DISPLAY_HZ` | Flag High Refresh Rate & Adaptive FPS user-space (tidak menyentuh `fpsList` XML) | **Medium GPU** | OFF (`auto`) | OFF (`auto`) | ON (`auto`) |
| `FEAT_COLOR_EXPERT` | Custom Color Scheme (`support_display_expert_mode=true` XML, tanpa mengganggu 3 mode bawaan) | **Low Load** | OFF (`0`) | OFF (`0`) | OFF (`0`) |
| `FEAT_GALLERY_PRO` | Tag XML Galeri nyata (video compress, time-burst, Dolby, print, analisis wajah/adegan; HyperOS SDK ≥ 34) | **XML Only** | OFF (`0`) | OFF (`0`) | OFF (`0`) |
| `FEAT_AOD_UNLOCK` | Hapus batas 10 detik AOD (`CoreSurfaceMiuiAod` RRO + XML AON + pembukaan tier native di `MiuiAod`, aman HOS 3 tanpa crash `mFullAodHideEase`) | **Low Load** | OFF (`0`) | OFF (`0`) | OFF (`0`) |

---

## Instalasi Singkat

1. Flash `CoreSurface-v1.0.0.zip` melalui **KernelSU-Next** (pastikan metamodule `meta-overlayfs` aktif untuk RRO) lalu reboot 1 kali saat suhu perangkat normal.
2. `service.sh` otomatis memasang `CoreSurfaceEngine.apk` (~29 KB) setelah SystemUI stabil 30 detik (atau klik **"Install / Update CoreSurfaceEngine.apk"** di WebUI).
3. Buka **LSPosed / Vector → Modules → aktifkan CoreSurface Engine** (scope otomatis: `System UI`, `System Launcher / MiuiHome`, `Always-on Display`).
4. Buka **KernelSU-Next → Modules → CoreSurface → Open WebUI**: pilih langsung profil **HyperOS 4**, **iOS · ColorOS 17**, atau **Stock** — aktif seketika **tanpa perlu reboot lagi**.

---

## Pengujian Lokal & Packaging

```sh
# Lint seluruh skrip POSIX sh
shellcheck -s sh -x customize.sh post-fs-data.sh service.sh uninstall.sh lib/*.sh scripts/*.sh tests/*.sh

# Validasi sintaks JS WebUI
node --check webroot/app.js

# Jalankan unit test host
sh tests/run_tests.sh

# Bangun RRO, CoreSurfaceEngine.apk, & dist/CoreSurface-v1.0.0.zip
sh scripts/package.sh
```

---

## References / Credits

- Inspirasi konsep pembukaan kapabilitas *user-space* HyperOS dan referensi tag `device_features` merujuk secara jujur kepada **[`ukriu/HyperUnlocked`](https://github.com/ukriu/HyperUnlocked)**. Seluruh kode skrip, arsitektur pengaman, XML patcher fail-closed, RRO source, Folme & SpringForce Motion Engine, Native Tier Unlock, Surgical Guard, verifier, WebUI, dan pengujian pada CoreSurface ditulis ulang sepenuhnya (*clean-room*) dari nol.
