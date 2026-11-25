# CoreSurface v1.0.0

**CoreSurface** adalah suite *user-space* HyperOS/MIUI **Hybrid Zero-Gimmick** yang ditulis ulang sepenuhnya dari nol (*clean-room*), menggabungkan:
1. **Layer 1 — CoreSurface KernelSU-Next / Magisk Base:** Pondasi properti terverifikasi non-persisten (`resetprop -n`), *Dynamic `device_features` XML Patcher* fail-closed, 5 *Clean-Room RRO Overlays*, Watchdog anti-bootloop, dan *Transactional Settings Rollback*.
2. **Layer 2 — CoreSurface Luminous & Flagship Engine (`CoreSurfaceEngine.apk`, ~30 KB, LSPosed):** Mesin runtime Java **HWUI Zero-FBO DisplayList** (0 FBO offscreen, 120 FPS mulus) + **Native HyperOS Flagship Tier Unlock** (membuka gerbang `DeviceLevel`/`DeviceConfig`/`CpuLevel` bawaan Xiaomi tanpa bentrok Folme), dengan hot-reload instan bebas Binder via `debug.coresurface.cfg` (**tanpa reboot**) dan **Thermal-Adaptive Visual LOD**.

Dirancang sebagai *sister module* (pendamping terpisah) dari **CoreFlow-Engine** dengan prinsip **Zero Coupling** & **Zero Gimmick**.

---

## Prinsip Arsitektur (Anti-Gimmick)

- **Zero Gimmick Policy:** Seluruh properti plasebo yang tidak dibaca binary ROM (seperti flag palsu Island/AI/AOD) telah dihapus total. Setiap lencana `Verified Active` di WebUI membutuhkan bukti runtime nyata (`getprop`, `/proc/mounts`, `cmd overlay list`, atau telemetri proses live `RENDERER=HWUI_ZERO_FBO` & `NATIVE_GATES` dari `SystemUI`/`MiuiHome`/`MiuiAod`).
- **Zero Coupling dengan CoreFlow-Engine:** 100% mandiri di *user-space*. CoreSurface **tidak pernah** menyentuh `uclamp`, `thermal_zone`, `sysfs` CPU/GPU/storage, atau parameter kernel/scheduler. *Thermal-Adaptive Visual LOD* memakai API resmi Android `PowerManager.OnThermalStatusChangedListener`.
- **Zero-Hardcode Device List:** Tidak pernah menulis codename HP secara statis. Semua deteksi menggunakan runtime `ro.mi.os.version.name`, `ro.miui.ui.version.name`, `ro.build.version.sdk`, `ro.product.device`, dan `/proc/meminfo`.
- **Non-Persistent & Clean Rollback:** Seluruh properti wajib menggunakan **`resetprop -n`** (memori saja, tidak pernah menghasilkan `system.prop` atau menulis `/data/property`), dan semua perubahan `settings` dibackup otomatis untuk rollback bersih.
- **Zero Binary Blobs di Git:** Seluruh RRO Overlays (`overlays-src/`) dan `CoreSurfaceEngine.apk` (`engine-src/`) dikompilasi dan ditandatangani langsung dari source saat packaging/CI.

---

## Fitur Live Engine (LSPosed — Hot-Reload Instan Tanpa Reboot via `debug.coresurface.cfg`)

| Kunci Fitur | Cakupan Nyata (Zero Gimmick, 120 FPS) | Default | Catatan |
| :--- | :--- | :---: | :--- |
| `FEAT_LUMINOUS_GLASS` | **Luminous Optical Glass (HWUI Zero-FBO):** bevel kaca spekular terarah + kilau atas optik pada tile Control Center, Slider, Media Card, & Folder | `auto` (SDK ≥ 33 & RAM ≥ 6 GB) | 0 FBO offscreen, maks 24 tile ter-dedup (anti nested subview), 0 polling sensor → 120 FPS tanpa lag. |
| `FEAT_LUMINOUS_TILT` | **Touch Specular Glass Ripple:** kilau cahaya radial mengikuti titik jari saat tile ditekan | `auto` (RAM ≥ 8 GB) | **0% idle drain** — hanya aktif saat disentuh, tidak memodifikasi click/drag slider. |
| `FEAT_LIVING_FLOW` | **Native HyperOS Flagship Tier Unlock:** membuka gerbang `DeviceLevelUtils` / `DeviceConfig` / `CpuLevelUtils` / `GpuLevelUtils` / `DeviceUtils` bawaan Xiaomi | `auto` (ON) | Menjalankan animasi flagship bawaan HyperOS tanpa bentrok Folme. |
| `FEAT_SURGICAL_GUARD` | **HyperOS 3 Surgical Toast & Recents Guard:** memblokir blur rusak pada jendela Toast pop-up & mengganti scrim hitam Recent Apps menjadi kaca transparan | `auto` (ON) | Memperbaiki bug Toast melebar & Recent Apps hitam HyperOS 3 secara bedah tanpa mematikan blur Control Center. |
| `FEAT_THERMAL_LOD` | **Thermal-Adaptive Visual LOD** (*CoreSurface Exclusive*): otomatis menyesuaikan detail glass overlay `FULL → BALANCED → ECO` mengikuti status termal Android | `auto` (ON) | Menjaga 120 FPS tetap mulus saat perangkat hangat/gaming. |

---

## Fitur Early-Boot Base (`/data/adb/coresurface/config.prop` & WebUI)

| Kunci Fitur | Cakupan | Beban Hardware | Default `< 6 GB` | Default `6–7 GB` | Default `>= 8 GB` |
| :--- | :--- | :---: | :---: | :---: | :---: |
| `FEAT_BLUR` | SurfaceFlinger & HyperOS CC/Shade/Folder/Launcher Blur (`disable_window_blurs=0`; di HOS 3+ menjaga default *Advanced textures* OFF agar aman) | **High GPU/RAM** | OFF (`auto`) | ON (`auto`) | ON (`auto`) |
| `FEAT_ANIMATIONS` | `HyperTransition`, `parallel_sweep`, `debug.sysui.use_control_center=1`, & `deviceLevelList` dinamis | **Medium RAM** | ON (Lvl 2) | ON (Lvl 2+) | ON (Lvl 3) |
| `FEAT_XML_PATCHER` | Dynamic `device_features` XML Patcher (add-only, non-destruktif, SELinux `chcon --reference`) | **Low Load** | ON (`auto`) | ON (`auto`) | ON (`auto`) |
| `FEAT_RRO_OVERLAYS` | 5 Clean-Room RRO APKs (`SystemUI`, `SystemUI Lite Blur`, `ThemeManager`, `MiWallpaper`, `MiuiAod`) | **Medium GPU** | OFF (`auto`) | ON (`auto`) | ON (`auto`) |
| `FEAT_VIDEO_DEPTH` | Lockscreen Video Depth (`enable_video_depth` zero-byte marker) | **Low Load** | OFF (`auto`) | ON (`auto`) | ON (`auto`) |
| `FEAT_MULTITASK` | Relaksasi `low_ram` & ambang GB, Freeform (`max_count=4`), One-Handed Mode, Partial Screenshot | **Medium RAM** | OFF (`auto`) | OFF (`auto`) | ON (`auto`) |
| `FEAT_DISPLAY_HZ` | Flag High Refresh Rate & Adaptive FPS user-space (tidak menyentuh `fpsList` XML) | **Medium GPU** | OFF (`auto`) | OFF (`auto`) | ON (`auto`) |
| `FEAT_COLOR_EXPERT` | Custom Color Scheme (`support_display_expert_mode=true` XML, tanpa mengganggu 3 mode bawaan) | **Low Load** | OFF (`0`) | OFF (`0`) | OFF (`0`) |
| `FEAT_GALLERY_PRO` | Tag XML Galeri nyata (video compress, time-burst, Dolby, print, analisis wajah/adegan; HyperOS SDK ≥ 34) | **XML Only** | OFF (`0`) | OFF (`0`) | OFF (`0`) |
| `FEAT_AOD_UNLOCK` | Hapus batas 10 detik AOD (`CoreSurfaceMiuiAod` RRO + XML AON) + transisi halus AOD → Lockscreen via LivingFlow Engine (aman HOS 3 tanpa crash `mFullAodHideEase`) | **Low Load** | OFF (`0`) | OFF (`0`) | OFF (`0`) |

---

## Instalasi Singkat

1. Flash `CoreSurface-v1.0.0.zip` melalui **KernelSU-Next** (pastikan metamodule `meta-overlayfs` aktif untuk RRO) lalu reboot 1 kali saat suhu perangkat normal.
2. `service.sh` otomatis memasang `CoreSurfaceEngine.apk` (~33 KB) setelah SystemUI stabil 30 detik (atau klik **"Install / Update CoreSurfaceEngine.apk"** di WebUI).
3. Buka **LSPosed / Vector → Modules → aktifkan CoreSurface Engine** (scope otomatis: `System UI`, `System Launcher / MiuiHome`, `Always-on Display`).
4. Buka **KernelSU-Next → Modules → CoreSurface → Open WebUI**: semua kontrol **Live Luminous & LivingFlow** langsung aktif dalam hitungan milidetik **tanpa perlu reboot lagi**.

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

- Inspirasi konsep pembukaan kapabilitas *user-space* HyperOS dan referensi tag `device_features` merujuk secara jujur kepada **[`ukriu/HyperUnlocked`](https://github.com/ukriu/HyperUnlocked)**. Seluruh kode skrip, arsitektur pengaman, XML patcher fail-closed, RRO source, AGSL Luminous Shader, LivingFlow Spring Physics Engine, Surgical Guard, verifier, WebUI, dan pengujian pada CoreSurface ditulis ulang sepenuhnya (*clean-room*) dari nol.
