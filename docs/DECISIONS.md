# Engineering decision record

## 2026-11-02: Fitur harus punya evidence, bukan sekadar flag

**Keputusan:** status fitur dipisah menjadi Discovered / Advertised / Exposed / Functional / Measured. Saat ini WCG baru Exposed; Expert/HFR belum Functional.

**Alasan:** sebelumnya WCG terlihat sukses di pengaturan Framework, tetapi `Current color mode` tetap sRGB pada eksperimen browser; itu belum mengukur color gamut panel. Slow Motion ada di APK tetapi runtime gate terobfusikasi.

## 2026-11-02: Satu modul, bukan banyak ZIP

**Keputusan:** pertahankan ID `kunzite_wcg_probe`, tambahkan eksperimen secara opt-in di satu suite, dengan WebUI tunggal dan rollback. Tidak lagi membuat modul per flag.

**Alasan:** modul WCG sebelumnya mengalami beberapa hotfix status dan reboot; penggunaan banyak modul meningkatkan konflik serta kesulitan reproduksi.

## 2026-11-02: Audit dan docs dulu, reboot terakhir

**Keputusan:** semua bukti firmware, APK, vendor config dan HAL disimpan dalam dokumen audit yang bisa ditinjau. Pengujian perangkat setelah review source dan satu rencana acceptance test, bukan setiap penemuan kecil.

## 2026-11-02: Hindari vendor blobs di Git

**Keputusan:** XML vendor/APK kamera tidak di-commit. Build menerima XML stock lokal dengan SHA-256 yang cocok sebagai bahan artefak, tanpa membuat salinan persisten di repo.

**Alasan:** hak distribusi vendor dan risiko data perangkat; sumber Git tetap bisa diaudit.

## Batas scope

Tidak memaksa fitur yang tidak diekspos jalur aktif: HDR10/Dolby Vision, OIS, 1080p60, ray tracing/mesh shader. Tidak ada thermal bypass, overclock, atau polling daemon.

## 2026-11-02: Koreksi Slow Motion asli

Pengguna menemukan menu Slow Motion pada Kamera Xiaomi bawaan, sehingga hipotesis sebelumnya bahwa `support_video_hfr_mode=false` menyembunyikan menu tidak tepat. Keberadaan menu telah diamati; FPS video sebenarnya belum diukur. **Keputusan:** HFR dihapus dari fitur mutasi; kontrol legacy hanya mengizinkan OFF, marker lama dibersihkan saat boot, XML asli dipertahankan. Audit lama tetap disimpan sebagai sejarah koreksi.
