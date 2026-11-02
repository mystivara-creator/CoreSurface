# Indeks bukti dan sumber

Setiap perubahan harus diikat ke **nilai sumber**, **metode verifikasi**, dan **hasil runtime**. Tidak boleh menyatakan "unlock berhasil" hanya karena flag atau properti berubah.

## Dataset 2026-11-02

- [`audits/2026-11-02-capabilities.md`](audits/2026-11-02-capabilities.md): 11 berkas audit *read-only*, ringkasan `properties`, Camera2, codec, display, grafik, fitur, panel, dan konflik properti. Berkas mentah tidak disimpan karena dapat mengandung identitas hardware.
- [`audits/2026-11-02-camera-apk.md`](audits/2026-11-02-camera-apk.md): analisis statis 7 DEX MiuiCamera dan XML konfigurasi, termasuk jalur `SlowMotionModuleEntry.support()`.
- Sumber vendor yang **hanya tersedia pada perangkat**: `/product/etc/device_features/kunzite.xml`, `/odm/etc/display/qdcm_calib_data_dsi_p17_41_02_0a_amoled_video_mode_dsi_panel_with_DSC.json`.
- Firmware APK Kamera proprietary dan konfigurasi panel asli **tidak disalin ke GitHub**.

## Gradasi validasi

1. **Discovered:** nama properti/file/kelas ditemukan.
2. **Advertised:** HAL/API atau Settings melaporkan fitur.
3. **Exposed:** setelah modifikasi, Framework mengekspos kemampuan (contoh: P3 (9)).
4. **Functional:** aplikasi memang menggunakan kemampuan (contoh: layer P3 atau video 720p120 yang tersimpan).
5. **Measured:** hasil nyata diverifikasi (warna dengan instrumen atau metadata FPS dan hasil frame capture).

WCG baru mencapai **Exposed**; HFR dan Expert Mode belum mencapai Functional.

## Artefak yang tidak boleh dibuang dari audit

- Identitas model, firmware dan panel; bukti versi driver; nilai baseline sebelum modul.
- Bukti A/B dengan dan tanpa modul, langkah reproduksi, serta log kegagalan.
- SHA-256 berkas OEM ketika dibutuhkan untuk pemeriksaan kompatibilitas.

Hindari mengunggah IMEI, serial, token, informasi akun, atau log mentah yang bisa mengungkap data pribadi.
