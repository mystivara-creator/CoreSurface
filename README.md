# CoreSurface v1.0.0

**CoreSurface** adalah modul KernelSU-Next / Magisk *clean-room* untuk membuka fitur *user-space* HyperOS/MIUI yang dipangkas vendor secara dinamis, terverifikasi, dan aman, dirancang sebagai *sister module* (pendamping terpisah) dari **CoreFlow-Engine**.

## Prinsip Arsitektur

- **Zero Coupling dengan CoreFlow-Engine:** 100% mandiri di *user-space*. CoreSurface **tidak pernah** menyentuh `uclamp`, `thermal_zone`, `sysfs` CPU/GPU/storage, atau parameter kernel/scheduler.
- **Zero-Hardcode Device List:** Tidak pernah menulis codename HP secara statis. Semua penemuan fitur dan profil menggunakan deteksi runtime (`ro.mi.os.version.name`, `ro.miui.ui.version.name`, `ro.build.version.sdk`, `ro.product.device`, dan `/proc/meminfo`).
- **Non-Persistent & Clean Rollback:** Seluruh properti diterapkan wajib dengan **`resetprop -n`** (memori saja, tidak pernah menulis ke `/data/property`), sementara seluruh penyesuaian Android `settings` dicadangkan secara idempoten dan di-rollback bersih saat fitur dimatikan atau modul di-uninstall.
- **POSIX Shell & Lulus CI:** Semua skrip ditulis ulang dari nol dengan POSIX `sh`, lulus `shellcheck -s sh -x`, dan diverifikasi oleh suite unit test host di GitHub Actions.

---

## Kontrol Fitur Granular (`/data/adb/coresurface/config.prop` & WebUI)

| Kunci Fitur | Cakupan | Beban Hardware | Default `< 6 GB` | Default `6–7 GB` | Default `>= 8 GB` | Catatan |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| `FEAT_BLUR` | Advanced Textures, Background Blur, CC/Folder Blur, `disable_window_blurs=0` | **High GPU/RAM** | OFF (`auto`) | ON (`auto`) | ON (`auto`) | Otomatis nonaktif pada RAM < 6 GB demi kestabilan memori. |
| `FEAT_ANIMATIONS` | Flagship Animation & `ro.miui.device_level` / `deviceLevelList` | **Medium RAM** | ON (Lvl 2) | ON (Lvl 2+) | ON (Lvl 3) | Level animasi menyesuaikan kapasitas RAM aktual. |
| `FEAT_XML_PATCHER` | Dynamic `device_features` XML Patcher (non-destruktif, SELinux-safe `mount --bind`) | **Low Load** | ON (`auto`) | ON (`auto`) | ON (`auto`) | *Fail-closed*; melindungi tag display/color/`fpsList`/`double_tap` bawaan. |
| `FEAT_RRO_OVERLAYS` | Clean-Room RRO Overlays (SystemUI shade/gradient blur & charging ripple, ThemeManager Video Wallpaper, MiWallpaper Super Wallpaper) | **Medium GPU** | OFF (`auto`) | ON (`auto`) | ON (`auto`) | Dikompilasi dari source XML di CI (`aapt2`/`apksigner`); mendukung mode *Lite Blur* otomatis bila `FEAT_BLUR=0`. |
| `FEAT_ISLAND` | HyperOS Dynamic Island (animasi & shader) | **Low Load** | OFF (`auto`) | ON (HOS ≥ 2) | ON (HOS ≥ 2) | Aktif otomatis pada HyperOS 2/3 dengan RAM ≥ 6 GB. |
| `FEAT_VIDEO_DEPTH` | Lockscreen Video Depth (`enable_video_depth` zero-byte marker) | **Low Load** | OFF (`auto`) | ON (`auto`) | ON (`auto`) | Tanpa biner; ikut dibersihkan fail-closed oleh Watchdog. |
| `FEAT_MULTITASK` | Relaksasi `low_ram` & ambang GB, Freeform/Floating Window (`max_count=4`), One-Handed Mode, Partial Screenshot | **Medium RAM** | OFF (`auto`) | OFF (`auto`) | ON (`auto`) | Default aktif hanya pada perangkat RAM ≥ 8 GB. |
| `FEAT_DISPLAY_HZ` | Dukungan High Refresh Rate & Adaptive FPS user-space | **Medium GPU** | OFF (`auto`) | OFF (`auto`) | ON (`auto`) | Default aktif hanya pada perangkat RAM ≥ 8 GB (tidak menyentuh `fpsList` XML bawaan). |
| `FEAT_HYPERAI` | HyperAI & AI Galeri (`Opt-in`) | **High RAM** | OFF (`0`) | OFF (`0`) | OFF (`0`) | Opt-in eksplisit; otomatis di-gate hanya untuk HyperOS + Android SDK ≥ 34. |
| `FEAT_AOD_UNLOCK` | AOD Limit Unlock (`Opt-in`) | **Low Load** | OFF (`0`) | OFF (`0`) | OFF (`0`) | Opt-in eksplisit; otomatis melewati `support_aod_fullscreen` di HyperOS 3+. |

### Preset Profil 1-Klik & Aksi Cepat di WebUI
- **Stock Safe:** Paling ringan & hemat daya (hanya animasi & XML non-destruktif; langsung me-rollback `settings` dan membersihkan RRO).
- **Balanced Daily:** Profil otomatis berbasis *Dynamic RAM Tiering* (`auto`).
- **Flagship Max:** Mengaktifkan seluruh 8 fitur UI/blur/RRO/Island/Video Depth secara penuh (tetap menjaga fitur eksperimental opt-in).
- **Hot-Apply Settings (Tanpa Reboot):** Menerapkan/me-rollback `settings --user 0` dan memverifikasi ulang secara instan.
- **ROM Compatibility Score (%) & Export Diagnostik 1-Klik:** Menampilkan persentase fitur aktif yang terverifikasi nyata serta menyalin laporan diagnostik bersih tanpa IMEI/serial.

---

## Arsitektur Pengaman & Verifikasi End-to-End

### 1. Empat Lapis Pengaman Anti-Bootloop
1. **ROM & SDK Gate (`lib/detect.sh`):** Memeriksa `ro.mi.os.version.name` / `ro.miui.ui.version.name` di awal `post-fs-data.sh`. Jika bukan HyperOS/MIUI, segera `exit 0` tanpa menulis satu pun properti dan mencatat `WATCHDOG_STATUS=unsupported_rom`.
2. **Dynamic Hardware Tiering (`lib/detect.sh`):** Mengklasifikasikan perangkat otomatis ke tier RAM (`< 6 GB`, `6–7 GB`, `>= 8 GB`) dari `/proc/meminfo`.
3. **Bootloop & SystemUI Watchdog (`lib/watchdog.sh`):**
   - Sebelum menerapkan `resetprop -n` atau XML mount, counter `/data/adb/coresurface/boot_strikes` dinaikkan (`+1`).
   - Jika `boot_strikes >= 2`, modul otomatis membuat file `disable`, membersihkan staging RRO overlay, mereset `boot_strikes=0`, mencatat `safe_mode_disabled`, dan `exit 0` (*fail-closed*).
   - Di `service.sh`, Watchdog menunggu `sys.boot_completed=1`, memberi *grace window* 30 detik agar `com.android.systemui` muncul, lalu memverifikasi PID tetap stabil selama **30 detik penuh** sebelum mereset `boot_strikes=0` dan menandai `healthy`.
4. **Safe-Mode Recovery di WebUI (`webroot/` & `lib/webui_ctl.sh`):** Menyediakan tombol **"Reset Safe-Mode & Aktifkan Kembali"** langsung dari WebUI.

### 2. Dynamic `device_features` XML Patcher (`lib/xml_patcher.sh`)
- **Auto-Discovery Tanpa Hardcode:** Mencari XML fitur bawaan perangkat secara dinamis menggunakan nilai runtime `getprop ro.product.device` pada jalur standar HyperOS/MIUI (`/mi_ext/product/etc/device_features`, `/product/etc/device_features`, `/system/etc/device_features`, `/vendor/etc/device_features`), dengan fallback ke file `.xml` valid pertama bila penamaan berbeda.
- **Non-Destructive, SELinux-Safe & Fail-Closed:** Menyalin ke `/data/adb/coresurface/work/device_features.xml`, hanya meng-upgrade `<bool>` dari `false -> true` dan tidak pernah menurunkan `<integer>` asli, melindungi tag display/color/`fpsList`/`double_tap`, memulihkan konteks SELinux (`chcon --reference`) sebelum `mount --bind`, dan melewatkan aman (`XML_STATUS=skipped`) bila gagal.

### 3. Clean-Room RRO Overlay Layer (`overlays-src/`, `scripts/build_overlays.sh`, `lib/rro.sh`)
- **Zero Biner di Git:** Seluruh RRO (`SystemUI`, `SystemUI Lite Blur`, `ThemeManager`, `MiWallpaper`) ditulis dalam XML source murni di `overlays-src/` dan dikompilasi serta ditandatangani otomatis oleh `aapt2` + `apksigner` saat packaging/CI.
- **Staging Dinamis & Fail-Closed:** `lib/rro.sh` hanya men-stage APK yang sesuai ke `$MODDIR/system/product/overlay/` saat `FEAT_RRO_OVERLAYS` aktif, dan langsung membersihkannya bila fitur dimatikan di WebUI atau Safe-Mode Watchdog terpicu.

### 4. Transactional `settings` Override & Clean Rollback (`lib/settings_tx.sh`)
- **Android 16 Binder-Safe (`--user 0`) & Backup Idempoten:** Menggunakan `settings --user 0` (dengan fallback versi Android lama), menyimpan nilai asli **sekali saja** ke `/data/adb/coresurface/settings_backup.prop`.
- **Auto-Rollback & Clean Uninstall:** Mematikan fitur di `config.prop` otomatis mengembalikan kunci `settings` terkait ke nilai aslinya (atau `settings delete` bila awalnya `null`). `uninstall.sh` menjalankan rollback penuh sebelum menghapus `/data/adb/coresurface/`.

### 5. User-Space Capability Verifier (`lib/verifier.sh`)
- Berjalan di `service.sh` setelah SystemUI dinyatakan stabil 30 detik.
- Membandingkan seluruh properti di `applied_props.list` terhadap `getprop` aktual, memeriksa status *bind-mount* `device_features` di `/proc/mounts`, memeriksa aktivasi RRO melalui `cmd overlay list --user 0`, serta memverifikasi `settings` aktif.
- Menulis hasil audit per fitur (`verified_active`, `ignored_by_rom`, `skipped`, atau `disabled`) ke `/data/adb/coresurface/verify.state` yang langsung ditampilkan sebagai lencana verifikasi di WebUI.

---

## Sinergi Pasif dengan CoreFlow-Engine

CoreSurface dan **CoreFlow-Engine** beroperasi pada lapisan yang sepenuhnya terpisah. WebUI CoreSurface secara pasif memeriksa keberadaan `/data/adb/modules/cfae_framework` dan proses aktif `pidof coreflowd`: bila keduanya aktif, WebUI menampilkan lencana **"CoreFlow Thermal Guard Active"**.

---

## Pengujian Lokal & Packaging

```sh
# Lint seluruh skrip POSIX sh
shellcheck -s sh -x customize.sh post-fs-data.sh service.sh uninstall.sh lib/*.sh scripts/*.sh tests/*.sh

# Validasi sintaks JS WebUI
node --check webroot/app.js

# Jalankan unit test host (mock getprop, resetprop, pidof, mount, settings, /proc/meminfo, /proc/mounts)
sh tests/run_tests.sh

# Bangun artefak ZIP produksi (dist/CoreSurface-v1.0.0.zip)
sh scripts/package.sh
```

---

## References / Credits

- Inspirasi konsep pembukaan kapabilitas *user-space* HyperOS dan referensi tag `device_features` merujuk secara jujur kepada **[`ukriu/HyperUnlocked`](https://github.com/ukriu/HyperUnlocked)**. Seluruh kode skrip, arsitektur pengaman, XML patcher fail-closed, transactional settings rollback, verifier, WebUI, dan pengujian pada CoreSurface ditulis ulang sepenuhnya (*clean-room*) dari nol.
