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
