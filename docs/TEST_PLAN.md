# Rencana pengujian dan acceptance criteria

## Sebelum perangkat: host checks

1. Validasi skrip `sh -n` dan `node --check` (jika tersedia).
2. Validasi HTML, konfigurasi dan integritas file package; ZIP harus punya daftar file minimal.
3. Pastikan dua feature flag eksperimen OFF default.
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
| Slow Motion | Menu tidak ada | Flag aktif via overlay | Mode muncul, video 720p120/240 terekam, metadata dan frame nyata sesuai |
| Rollback | Baseline stock | Matikan module/toggle | Properti dan konfigurasi kembali pada reboot berikutnya |
| Reboot/OTA | Baseline dikenal | Setelah perubahan | Modul gagal-aman pada fingerprint tidak cocok |

Jika fitur tidak memenuhi **kriteria hasil nyata**, label tetap *experimental/not verified*. Jangan me-release klaim unlock.

## Diagnostik yang boleh dibagikan

Sertakan versi modul, ROM, panel, flag/hasil runtime dan langkah reproduksi. Redaksi serial, perangkat jaringan, informasi akun, lokasi, token, atau log kamera berisi data pribadi.

## Pengujian host tambahan (2026-11-02)

- `scripts/tests/test_overlay.py` menjalankan skrip staging sungguhan dengan XML sintetis: default tanpa mount; Expert saja; HFR saja; keduanya; nonaktifkan kembali; baseline duplikat/hilang ditolak.
- `scripts/validate.py` memastikan gate SHA-256 ada di installer dan tahap boot.
- `scripts/tests/webui_bridge.cjs` menguji pembacaan status WebUI dengan respons bridge KernelSU string, object, dan Promise (jika Node.js tersedia).
- Pengujian host **tidak** memastikan OverlayFS terpasang di perangkat, menu Xiaomi tampil, ataupun akurasi warna. Eksperimen perangkat tetap memerlukan rencana rollback.

## Runtime overlay verification gate (host simulation)

`test_service.py` simulates the real service shell script using a fixture XML at a test-only path, without touching the Android device. It checks that boot completion does not count as feature activation unless each opted-in flag appears in the mounted XML. On mismatch, the `boot_pending` marker stays in place and a recovery reason is stored for rollback at the next boot. **This is not an on-device mount test.**

## Lokasi payload meta-overlayfs

Host test harus memastikan `product/` dipakai (bukan `system/product/`), `skip_mount` **tidak** dilepas selama staging XML biasa, dan hanya dilepas setelah berhasil menyalin ke ext4 image. Validasi perangkat harus memeriksa `/product/etc/device_features/kunzite.xml` efektif serta opsi aplikasi, tanpa mengklaim sukses dari flag tertulis di staging.
