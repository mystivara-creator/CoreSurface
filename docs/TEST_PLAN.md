# Rencana pengujian dan acceptance criteria

## Sebelum perangkat: host checks

1. Validasi skrip `sh -n` dan `node --check` (jika tersedia).
2. Validasi HTML, konfigurasi dan integritas file package; ZIP harus punya daftar file minimal.
3. Pastikan Expert Mode default OFF dan tidak ada kemampuan mengaktifkan HFR.
4. Pastikan build menolak XML dengan hash berbeda, file kosong, atau XML dari ROM lain.
5. Periksa tidak ada data mentah pengguna, APK proprietary, atau token dalam Git.

## Pada perangkat (hanya jika siap recovery)

| Uji | Baseline | Dengan modul | Kriteria berhasil |
|---|---|---|---|
| Boot aman | Boot normal | Boot normal | Tanpa bootloop dan permission error |
| WCG | `SurfaceFlinger` `[0,7]` | `[0,7,9]` | Exposed pada framework; tidak harus force P3 |
| WCG aplikasi | Konten sRGB | Aplikasi P3 native | Layer/mode P3 sesuai permintaan; bukti bukan cuma prop |
| P3 kualitas | Uji visual terbatas | Colorimeter/alat kalibrasi | Akurasi gamut yang terukur |
| Expert UI | Menu disembunyikan | Flag aktif via overlay | Menu muncul dan nilai berubah konsisten serta reversible |
| Slow Motion bawaan | Menu ada di kamera Xiaomi | Modul tidak mengubah HFR | UI tetap tersedia; FPS hanya dinyatakan setelah pengukuran rekaman |
| Rollback | Baseline stock | Matikan module/toggle | Properti dan konfigurasi kembali pada reboot berikutnya |
| Reboot/OTA | Baseline dikenal | Setelah perubahan | Modul gagal-aman pada fingerprint tidak cocok |

Jika fitur tidak memenuhi **kriteria hasil nyata**, label tetap *experimental/not verified*. Jangan me-release klaim unlock.

## Diagnostik yang boleh dibagikan

Sertakan versi modul, ROM, panel, flag/hasil runtime dan langkah reproduksi. Redaksi serial, perangkat jaringan, informasi akun, lokasi, token, atau log kamera berisi data pribadi.

## Pengujian host tambahan (2026-11-02)

- `scripts/tests/test_overlay.py` menjalankan skrip staging sungguhan dengan XML sintetis: default tanpa mount; Expert saja; marker HFR lama diabaikan; nonaktifkan kembali; baseline duplikat/hilang ditolak.
- `scripts/validate.py` memastikan gate SHA-256 ada di installer dan tahap boot.
- `scripts/tests/webui_bridge.cjs` menguji pembacaan status WebUI dengan respons bridge KernelSU string, object, dan Promise (jika Node.js tersedia).
- Pengujian host **tidak** memastikan OverlayFS terpasang di perangkat, menu Xiaomi tampil, ataupun akurasi warna. Eksperimen perangkat tetap memerlukan rencana rollback.

## Runtime overlay verification gate (host simulation)

`test_service.py` simulates the real service shell script using a fixture XML at a test-only path, without touching the Android device. It checks that boot completion does not count as feature activation unless each opted-in flag appears in the mounted XML. On mismatch, the `boot_pending` marker stays in place and a recovery reason is stored for rollback at the next boot. **This is not an on-device mount test.**

## Lokasi payload meta-overlayfs

Host test harus memastikan `product/` dipakai (bukan `system/product/`), `skip_mount` **tidak** dilepas selama staging XML biasa, dan hanya dilepas setelah berhasil menyalin ke ext4 image. Validasi perangkat harus memeriksa `/product/etc/device_features/kunzite.xml` efektif serta opsi aplikasi, tanpa mengklaim sukses dari flag tertulis di staging.

## Installer sourced-shell regression (2026-11-02)

- KernelSU-Next loads `customize.sh` via dot-source in its installer, not as an isolated process.
- Test models KernelSU `set_perm` reading optional `$5` with four arguments and confirms source script never leaks `set -e` or `set -u` into the installer shell.
- Permission failures emit an explicit `abort` message instead of generic flash failure.
- Firmware gates unchanged. Host simulation does not establish live compatibility with device mounts.

## WebUI bridge bug caught on device (v0.6.4-preview)

- Under KernelSU-Next `WebViewInterface.kt`, synchronous `ksu.exec(cmd)` delegates to `ShellUtils.fastCmd` and may return only **last stdout line**, evidenced by the user seeing only `expert_ui_result=not_verified`.
- Use callback API `ksu.exec(cmd, callbackName)`, which returns `exitCode`, joined multiline `stdout`, and `stderr`. A 30-second timer handles missing callback response.
- Tests mimic native method overload and refuse one-argument calls, asserting all status fields/logs are visible, toggle responses still work, and truncated reports produce explicit errors. Android UI should update immediately after installed HTML is refreshed, without reboot.
- **Jangan reboot ketika penanda HFR lama masih aktif.** v0.6.5 menghapus mutasi HFR; Expert Mode perlu uji tersendiri.

## v0.6.5 regression

- Pastikan `set hfr on` ditolak, `set hfr off` hanya menghapus marker legacy, dan tidak ada tombol HFR di WebUI.
- `prepare-overlay.sh` harus mempertahankan `support_video_hfr_mode=false` meskipun `hfr_enabled` lama masih ada.
- `post-fs-data.sh` harus membuang marker HFR lama sebelum staging, tanpa memengaruhi WCG.
