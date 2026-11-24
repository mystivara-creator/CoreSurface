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
| `FEAT_XML_PATCHER` | Dynamic `device_features` XML Patcher (`mount --bind`) | **Low Load** | ON (`auto`) | ON (`auto`) | ON (`auto`) | *Fail-closed*; hanya menambal tag sesuai fitur yang aktif. |
| `FEAT_MULTITASK` | Relaksasi `low_ram`, Freeform/Floating Window (`max_count=4`) | **Medium RAM** | OFF (`auto`) | OFF (`auto`) | ON (`auto`) | Default aktif hanya pada perangkat RAM ≥ 8 GB. |
| `FEAT_DISPLAY_HZ` | Dukungan High Refresh Rate & Adaptive FPS user-space | **Medium GPU** | OFF (`auto`) | OFF (`auto`) | ON (`auto`) | Default aktif hanya pada perangkat RAM ≥ 8 GB. |
| `FEAT_HYPERAI` | HyperAI & AI Galeri (`Opt-in`) | **High RAM** | OFF (`0`) | OFF (`0`) | OFF (`0`) | Opt-in eksplisit; otomatis di-gate hanya untuk HyperOS + Android SDK ≥ 34. |
| `FEAT_AOD_UNLOCK` | AOD Limit Unlock (`Opt-in`) | **Low Load** | OFF (`0`) | OFF (`0`) | OFF (`0`) | Opt-in eksplisit; otomatis melewati `support_aod_fullscreen` di HyperOS 3+. |

---

## Arsitektur Pengaman & Verifikasi End-to-End

### 1. Empat Lapis Pengaman Anti-Bootloop
1. **ROM & SDK Gate (`lib/detect.sh`):** Memeriksa `ro.mi.os.version.name` / `ro.miui.ui.version.name` di awal `post-fs-data.sh`. Jika bukan HyperOS/MIUI, segera `exit 0` tanpa menulis satu pun properti dan mencatat `WATCHDOG_STATUS=unsupported_rom`.
2. **Dynamic Hardware Tiering (`lib/detect.sh`):** Mengklasifikasikan perangkat otomatis ke tier RAM (`< 6 GB`, `6–7 GB`, `>= 8 GB`) dari `/proc/meminfo`.
3. **Bootloop & SystemUI Watchdog (`lib/watchdog.sh`):**
   - Sebelum menerapkan `resetprop -n` atau XML mount, counter `/data/adb/coresurface/boot_strikes` dinaikkan (`+1`).
   - Jika `boot_strikes >= 2`, modul otomatis membuat file `disable`, mereset `boot_strikes=0`, mencatat `safe_mode_disabled`, dan `exit 0` (*fail-closed*).
   - Di `service.sh`, Watchdog menunggu `sys.boot_completed=1`, memberi *grace window* 30 detik agar `com.android.systemui` muncul, lalu memverifikasi PID tetap stabil selama **30 detik penuh** sebelum mereset `boot_strikes=0` dan menandai `healthy`.
4. **Safe-Mode Recovery di WebUI (`webroot/` & `lib/webui_ctl.sh`):** Menyediakan tombol **"Reset Safe-Mode & Aktifkan Kembali"** langsung dari WebUI.

### 2. Dynamic `device_features` XML Patcher (`lib/xml_patcher.sh`)
- **Auto-Discovery Tanpa Hardcode:** Mencari XML fitur bawaan perangkat secara dinamis menggunakan nilai runtime `getprop ro.product.device` pada jalur standar HyperOS/MIUI (`/mi_ext/product/etc/device_features`, `/product/etc/device_features`, `/system/etc/device_features`, `/vendor/etc/device_features`), dengan fallback ke file `.xml` valid pertama bila penamaan berbeda.
- **Safe Patching & Fail-Closed Bind-Mount:** Menyalin ke `/data/adb/coresurface/work/device_features.xml`, menambal hanya tag `<bool>` & `<integer>` milik fitur aktif dengan POSIX `awk`, memvalidasi struktur `<features>...</features>` tidak rusak/kosong, baru menjalankan `mount --bind`. Kegagalan apa pun langsung dilewati (`XML_STATUS=skipped`) tanpa mengganggu proses boot.

### 3. Transactional `settings` Override & Clean Rollback (`lib/settings_tx.sh`)
- **Backup Idempoten:** Sebelum memodifikasi kunci Android `settings` (`global`/`system`/`secure`), nilai asli dibaca lewat `settings get` dan disimpan **sekali saja** ke `/data/adb/coresurface/settings_backup.prop`.
- **Auto-Rollback & Clean Uninstall:** Mematikan fitur di `config.prop` otomatis mengembalikan kunci `settings` terkait ke nilai aslinya (atau `settings delete` bila awalnya `null`). `uninstall.sh` menjalankan rollback penuh sebelum menghapus `/data/adb/coresurface/`.

### 4. User-Space Capability Verifier (`lib/verifier.sh`)
- Berjalan di `service.sh` setelah SystemUI dinyatakan stabil 30 detik.
- Membandingkan seluruh properti di `applied_props.list` terhadap `getprop` aktual, memeriksa status *bind-mount* `device_features` di `/proc/mounts`, serta memverifikasi `settings` aktif.
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
