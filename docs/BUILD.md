# Build dan penggunaan source

Butuh Python 3.9+, Bash/POSIX shell, dan tools opsional `node` untuk validasi JavaScript. Tidak butuh Android NDK.

## Menyiapkan source OEM secara lokal

Pada perangkat yang firmware-nya **sama persis** dengan [compatibility](COMPATIBILITY.md), salin XML milik perangkat ke area privat, misalnya:

```sh
su -c 'cp /product/etc/device_features/kunzite.xml /sdcard/Download/kunzite.xml'
```

Jangan menaruh `kunzite.xml` di repository publik, issue, atau PR. Salin ke komputer pengembang sendiri, lalu jalankan:

```sh
python3 scripts/validate.py
python3 scripts/package.py --stock-xml /path/to/private/kunzite.xml
```

`package.py` melakukan pemeriksaan SHA-256 dan validasi kedua boolean sebelum membuat ZIP. Jika firmware berubah, **jangan bypass checksum**; lakukan audit kompatibilitas baru.

ZIP hasil ada di `dist/`. Ini preview, jangan anggap siap flash tanpa pengujian recovery. Baca [TEST_PLAN](TEST_PLAN.md).

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
