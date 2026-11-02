# Kunzite Capability Suite

Riset dan modul KernelSU untuk mengaudit serta menguji kemampuan yang tidak diekspos firmware **Redmi Note 15 5G** (`kunzite`, Qualcomm `parrot`). Proyek independen oleh **Mystivara**.

> **Status: v0.6.0-preview, belum rilis stabil.** Source disediakan untuk arsip pengembangan dan review. **Tidak ada klaim bahwa semua fitur sudah berhasil dibuka.** Jangan flash hasil build tanpa memeriksa kompatibilitas dan menyiapkan recovery.

## Hasil yang sudah dibuktikan

- **Wide Color Gamut (WCG):** Setelah perubahan properti `ro.surface_flinger.has_wide_color_display`, Android Framework dan SurfaceFlinger mengekspos `ColorMode::DISPLAY_P3 (9)` pada panel yang diaudit. **Belum membuktikan aplikasi merender P3 atau akurasi warna fisik panel.** Mode aktif default sRGB itu normal.
- **Slow Motion:** Kamera HAL mengekspos 720p120/240 pada beberapa Camera ID dan kode Slow Motion ditemukan di APK Kamera. Flag `support_video_hfr_mode=false`, tetapi **belum ditemukan cara tervalidasi untuk menampilkan menu atau merekam**.
- **Xiaomi Display Expert Mode:** `support_display_expert_mode=false` dan APK Settings mereferensikan flag tersebut. Perilaku UI/driver **belum teruji**.

**Tidak termasuk:** spoof HDR/Dolby Vision, 1080p60 tanpa HAL, overclock, thermal bypass, pemaksaan P3 global, OIS atau ray tracing palsu.

## Status fitur

| Fitur | Bukti | Implementasi preview | Teruji di perangkat |
|---|---|---|---|
| WCG / deklarasi P3 | Verified Framework | Aktif, hanya pada perangkat/ROM cocok | Ya, deklarasi saja |
| Rendering dan akurasi P3 | Tidak cukup bukti | Tidak dipaksa | Belum |
| Display Expert Mode | Kandidat pengaturan Xiaomi | **Opt-in**, default OFF | Belum |
| Camera Slow Motion 720p | Camera2 high-speed + kode APK | **Opt-in**, default OFF | Belum |
| 1080p60 / HDR / OIS | Dukungan tidak terbukti | Tidak diterapkan | Tidak |

Lihat [Feature Matrix](docs/FEATURE_MATRIX.md), [Audit Bukti](docs/EVIDENCE_INDEX.md), dan [Risk Register](docs/RISKS.md).

## Kompatibilitas dan migrasi

- `ro.product.device=kunzite`, `ro.board.platform=parrot`.
- ROM yang telah diaudit: `16OS3.1.260918.151434134.QCPEGL.S` (Android 16), bukan klaim semua ROM HyperOS.
- Panel yang telah diaudit: `mdss_dsi_p17_41_02_0a_amoled_dsc_vid`.
- Modul memakai **ID lama** `kunzite_wcg_probe` agar menggantikan modul WCG, bukan memasang dua modul dengan target sama. Jangan gabungkan dengan modul HFR lama.
- Experimental XML systemless memerlukan metamodule KernelSU yang kompatibel, dan tetap perlu pemeriksaan perangkat nyata. Kompatibilitas sistem mount belum dianggap terbukti.

## Source tree

```text
module/               Modul KernelSU preview (source)
  webroot/             WebUI dan pembacaan status
scripts/              Paket ZIP dari salinan firmware lokal, validasi
scripts/tests/        Pengujian statis di host
fixtures/             XML sintetis, BUKAN firmware perangkat
docs/audits/          Laporan audit tersanitasi
docs/                 Arsitektur, kompatibilitas, pengujian, rollback, risiko
.github/workflows/    Validasi CI
```

## Build tanpa menyebarkan file OEM

Repo **sengaja tidak memuat APK Kamera, data mentah `getprop`, atau XML vendor lengkap**. XML firmware dibaca dari perangkat milik sendiri saat membuat ZIP dan diverifikasi SHA-256:

```bash
python3 scripts/validate.py
python3 scripts/package.py --stock-xml /path/to/kunzite.xml
```

Hasil ada di `dist/kunzite_capability_suite_v0.6.0-preview.zip`. `--stock-xml` **wajib**; baca [BUILD](docs/BUILD.md). Tidak ada instalasi otomatis dalam proses build.

## Keamanan dan rollback

Tidak ada daemon polling atau modifikasi firmware asli. Sebelum pengujian, cadangkan boot/recovery dan ketahui cara menonaktifkan modul melalui KernelSU-Next/OrangeFox. Fitur eksperimental gagal-aman sebatas mekanisme yang tercantum pada [ROLLBACK](docs/ROLLBACK.md), **bukan jaminan anti-bootloop**.

## Dokumen utama

[Audit Bukti](docs/EVIDENCE_INDEX.md) · [Keputusan](docs/DECISIONS.md) · [Roadmap](ROADMAP.md) · [Pengujian](docs/TEST_PLAN.md) · [Arsitektur](docs/ARCHITECTURE.md) · [Changelog](CHANGELOG.md) · [Keamanan](SECURITY.md)

## Lisensi

Source proyek ini menggunakan **MIT License**. Berkas proprietary vendor tetap milik pemilik haknya dan tidak dimasukkan ke repo.
