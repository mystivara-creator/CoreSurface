# CoreSurface v1.0.0

**CoreSurface** adalah modul KernelSU-Next / Magisk *clean-room* untuk membuka fitur *user-space* HyperOS/MIUI yang dipangkas vendor secara dinamis dan aman, dirancang sebagai *sister module* (pendamping terpisah) dari **CoreFlow-Engine**.

## Prinsip Arsitektur

- **Zero Coupling dengan CoreFlow-Engine:** 100% mandiri. CoreSurface **tidak pernah** menyentuh `uclamp`, `thermal_zone`, `sysfs` CPU/GPU/storage, atau parameter kernel/scheduler. Fokus murni di *user-space* melalui `resetprop -n` (memori saja, tidak menulis permanen ke `/data/property`).
- **Zero-Hardcode Device List:** Tidak memfilter fitur berdasarkan codename perangkat. Semua keputusan didasarkan pada deteksi dinamis: `ro.mi.os.version.name` / `ro.miui.ui.version.name`, `ro.build.version.sdk`, dan kapasitas RAM aktual dari `/proc/meminfo`.
- **Clean-Room & POSIX Shell:** Seluruh skrip ditulis ulang dari nol dengan POSIX `sh` yang lulus `shellcheck -s sh` dan dilengkapi unit test host di CI.

---

## Perbandingan Tier Fitur (Opt-in via `/data/adb/coresurface/config.prop` & WebUI)

| Tier | Cakupan Fitur | Default `< 6 GB` | Default `6–7 GB` | Default `>= 8 GB` | Catatan Keamanan |
| :--- | :--- | :---: | :---: | :---: | :--- |
| **Tier 1 · Visual & UI** | `ro.miui.device_level`, `persist.sys.deviceLevelList`, Blur Control Center & Folder, Advanced Textures/Background Blur | **ON** (Ringan, tanpa heavy blur) | **ON** (Blur penuh, level 2) | **ON** (Flagship level 3 + blur penuh) | Nilai `auto` otomatis menyesuaikan intensitas blur & `deviceLevelList` terhadap RAM aktual. |
| **Tier 2 · System & Multitasking** | Relaksasi `ro.config.low_ram*`, batas floating window (`miui_freeform_max_count=4`), dukungan High Refresh Rate | **OFF** | **OFF** | **ON** | Default hanya aktif pada perangkat RAM ≥ 8 GB; dapat di-override manual ke `1` atau `0`. |
| **Tier 3 · Experimental** | **HyperAI / AI Galeri** (`TIER3_HYPERAI`) & **AOD Limit Unlock** (`TIER3_AOD_UNLOCK`) | **OFF** | **OFF** | **OFF** | Opt-in eksplisit dengan sub-toggle terpisah. HyperAI otomatis di-gate hanya untuk HyperOS + Android SDK ≥ 34. |

Semua properti diterapkan menggunakan **`resetprop -n`** (tanpa fallback non-`-n`), sehingga properti `persist.sys.*` tidak pernah menempel permanen di `/data/property` ketika modul di-uninstall atau dinonaktifkan oleh Watchdog.

---

## Empat Lapis Pengaman Anti-Bootloop

1. **ROM & SDK Gate (`lib/detect.sh`):** Memeriksa `ro.mi.os.version.name` / `ro.miui.ui.version.name` di awal `post-fs-data.sh`. Jika bukan HyperOS/MIUI, modul langsung `exit 0` tanpa menulis satu pun properti dan mencatat `WATCHDOG_STATUS=unsupported_rom`.
2. **Dynamic Hardware Tiering (`lib/detect.sh`):** Mengklasifikasikan perangkat otomatis ke tier RAM (`< 6 GB`, `6–7 GB`, `>= 8 GB`) dari `/proc/meminfo` untuk memilih profil default yang aman.
3. **Bootloop & SystemUI Watchdog (`lib/watchdog.sh`):**
   - Sebelum menerapkan `resetprop -n` di `post-fs-data.sh`, counter `/data/adb/coresurface/boot_strikes` dinaikkan (`+1`).
   - Jika `boot_strikes >= 2`, modul otomatis membuat file `disable`, mereset `boot_strikes=0`, mencatat `safe_mode_disabled` ke log, lalu `exit 0` (*fail-closed*).
   - Di `service.sh`, Watchdog menunggu `sys.boot_completed=1`, memberi *grace window* (30 detik) bagi `com.android.systemui` untuk muncul, lalu memverifikasi PID `com.android.systemui` tetap hidup stabil (tidak crash/berubah) selama **30 detik penuh** sebelum mereset `boot_strikes=0` dan menandai status `healthy`.
4. **Safe-Mode Recovery di WebUI (`webroot/` & `lib/webui_ctl.sh`):** Jika Safe-Mode terpicu, pengguna dapat meninjau alasan di WebUI, mematikan Tier 3 bila perlu, lalu menekan **"Reset Safe-Mode & Aktifkan Kembali"**.

---

## Sinergi Pasif dengan CoreFlow-Engine

CoreSurface dan **CoreFlow-Engine** beroperasi pada lapisan yang sepenuhnya terpisah (CoreSurface di *user-space UI/capability*, CoreFlow-Engine di *kernel/thermal/scheduler*). WebUI CoreSurface secara pasif memeriksa keberadaan `/data/adb/modules/cfae_framework` dan proses aktif `pidof coreflowd`: bila keduanya aktif, WebUI menampilkan lencana **"CoreFlow Thermal Guard Active"** sebagai indikator bahwa perlindungan termal pendamping sedang berjalan.

---

## Pengujian Lokal & Packaging

```sh
# Lint seluruh skrip POSIX sh
shellcheck -s sh -x customize.sh post-fs-data.sh service.sh uninstall.sh lib/*.sh scripts/*.sh tests/*.sh

# Jalankan unit test host (mock getprop, resetprop, pidof, /proc/meminfo)
sh tests/run_tests.sh

# Bangun artefak ZIP produksi (dist/CoreSurface-v1.0.0.zip)
sh scripts/package.sh
```

---

## References / Credits

- Inspirasi konsep pembukaan kapabilitas *user-space* HyperOS merujuk secara jujur kepada **[`ukriu/HyperUnlocked`](https://github.com/ukriu/HyperUnlocked)**. Seluruh skrip, arsitektur pengaman 4 lapis, WebUI, dan sistem pengujian pada CoreSurface ditulis ulang sepenuhnya (*clean-room*) dari nol.
