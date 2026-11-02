# Build dan penggunaan source

Butuh Python 3.9+, Bash/POSIX shell, dan tools opsional `node` untuk validasi JavaScript. Tidak butuh Android NDK.

## Build tanpa file OEM

```sh
python3 scripts/validate.py
python3 scripts/package.py
python3 scripts/verify_artifact.py
```

CI secara otomatis membangun dan mengunggah ZIP plus checksum SHA-256 pada **Actions → workflow run → Artifacts** (retensi 30 hari). Artifact tidak mengandung XML Xiaomi.

Ketika modul dipasang, `customize.sh` membaca `/product/etc/device_features/kunzite.xml`, memeriksa ROM, panel, dan hash SHA-256 yang diaudit. Hanya XML yang cocok yang disalin ke `$MODPATH/baseline/kunzite.xml`. XML vendor tetap berada di perangkat pengguna. Jika ROM berubah, instalasi gagal tertutup.

Opsi `--stock-xml /path/private/kunzite.xml` tersedia hanya untuk pemeriksaan checksum saat build manual. XML tersebut **tidak dimasukkan ZIP**. Artifact adalah preview dan tidak membuktikan fitur sudah berfungsi di perangkat.

## Publikasi ke GitHub

Repo ini dapat langsung dipush ke GitHub tanpa APK/ROM proprietary. File `dist/` dan baseline lokal dikecualikan `.gitignore`. **Repo ZIP menyertakan riwayat Git dan skrip publikasi**. Cara paling singkat dari Termux (dengan `gh` login sebagai `mystivara-creator`):

```sh
sh scripts/publish-termux.sh
```

Skrip membuat repository baru **private** bila belum ada, lalu push cabang `main` secara langsung. Ini memerlukan login GitHub aktif. Jika ingin manual dan repo sudah dibuat:

```sh
git remote add origin https://github.com/mystivara-creator/Kunzite-Capability-Suite.git
git branch -M main
git push -u origin main
```

Tidak perlu membuat PR; commit awal sudah disiapkan di cabang `main` pada paket Git bundle.
