# Kunzite Capability Suite

Riset dan modul KernelSU untuk mengaudit serta menguji kemampuan yang tidak diekspos firmware **Redmi Note 15 5G** (`kunzite`, Qualcomm `parrot`). Proyek independen oleh **Mystivara**.

> **Status: v0.6.5-preview, belum rilis stabil.** Source disediakan untuk arsip pengembangan dan review. **Tidak ada klaim bahwa semua fitur sudah berhasil dibuka.** Jangan flash hasil build tanpa memeriksa kompatibilitas dan menyiapkan recovery.

## Fokus Vulkan capabilities

Prioritas sekarang adalah **audit native Vulkan Adreno 710**, bukan WCG atau kamera. Gunakan `scripts/collect-vulkan.sh` (read-only) dan [protokol audit Vulkan](docs/VULKAN_AUDIT.md). Belum ada modifikasi Vulkan driver atau spoof extension dalam suite.

## Hasil yang sudah dibuktikan

- **Wide Color Gamut (WCG):** Setelah perubahan properti `ro.surface_flinger.has_wide_color_display`, Android Framework dan SurfaceFlinger mengekspos `ColorMode::DISPLAY_P3 (9)` pada panel yang diaudit. **Belum membuktikan aplikasi merender P3 atau akurasi warna fisik panel.** Mode aktif default sRGB itu normal.
- **Slow Motion:** Pengguna menemukan mode Slow Motion sudah tersedia di Kamera Xiaomi bawaan. HFR tidak memerlukan unlock; nilai `support_video_hfr_mode=false` tidak berarti menu kamera terkunci. FPS aktual hasil rekaman belum diukur.
- **Xiaomi Display Expert Mode:** `support_display_expert_mode=false` dan APK Settings mereferensikan flag tersebut. Perilaku UI/driver **belum teruji**.

**Tidak termasuk:** spoof HDR/Dolby Vision, 1080p60 tanpa HAL, overclock, thermal bypass, pemaksaan P3 global, OIS atau ray tracing palsu.

## Status fitur

| Fitur | Bukti | Implementasi preview | Teruji di perangkat |
|---|---|---|---|
| WCG / deklarasi P3 | Verified Framework | Aktif, hanya pada perangkat/ROM cocok | Ya, deklarasi saja |
| Rendering dan akurasi P3 | Tidak cukup bukti | Tidak dipaksa | Belum |
| Display Expert Mode | Kandidat pengaturan Xiaomi | **Opt-in**, default OFF | Belum |
| Camera Slow Motion | Mode tersedia di aplikasi Xiaomi bawaan | **Tidak dimodifikasi** | UI terbukti; FPS rekaman belum diukur |
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
scripts/              Build ZIP otomatis, validasi, dan tes installer
scripts/tests/        Pengujian statis di host
fixtures/             XML sintetis, BUKAN firmware perangkat
docs/audits/          Laporan audit tersanitasi
docs/                 Arsitektur, kompatibilitas, pengujian, rollback, risiko
.github/workflows/    Validasi CI dan upload ZIP artifact
```

## Build otomatis dan artifact GitHub Actions

ZIP tidak memuat APK Kamera atau XML vendor Xiaomi. Installer `customize.sh` mengambil XML dari perangkat saat instalasi, setelah memverifikasi ROM dan SHA-256.

```sh
python3 scripts/validate.py
python3 scripts/package.py
python3 scripts/verify_artifact.py
```

Hasil: `dist/kunzite_capability_suite_v0.6.5-preview.zip`. Setelah workflow berhasil, unduh melalui **Actions → workflow run → Artifacts**. Artifact berisi ZIP dan berkas `.sha256` dengan retensi 30 hari. `--stock-xml` opsional hanya untuk verifikasi lokal dan tidak menyertakan XML ke ZIP. Ini **preview**, bukan rilis stabil.

## Keamanan dan rollback

Tidak ada daemon polling atau modifikasi firmware asli. Sebelum pengujian, cadangkan boot/recovery dan ketahui cara menonaktifkan modul melalui KernelSU-Next/OrangeFox. Fitur eksperimental gagal-aman sebatas mekanisme yang tercantum pada [ROLLBACK](docs/ROLLBACK.md), **bukan jaminan anti-bootloop**.

## Dokumen utama

[Audit Bukti](docs/EVIDENCE_INDEX.md) · [Keputusan](docs/DECISIONS.md) · [Roadmap](ROADMAP.md) · [Pengujian](docs/TEST_PLAN.md) · [Arsitektur](docs/ARCHITECTURE.md) · [Changelog](CHANGELOG.md) · [Keamanan](SECURITY.md)

## Lisensi

Source proyek ini menggunakan **MIT License**. Berkas proprietary vendor tetap milik pemilik haknya dan tidak dimasukkan ke repo.
