# Contributing

Jangan push patch ke repo pihak lain. Pull request eksternal opsional; pemilik proyek memutuskan proses merge.

Untuk perubahan kode:
1. Sertakan evidence perangkat, ROM, panel, versi modul dan reproduksi.
2. Ubah satu fitur per eksperimen; pertahankan rollback, jangan memalsukan kemampuan API.
3. Jalankan `python3 scripts/validate.py` dan unit tests.
4. Perbarui `CHANGELOG.md`, `docs/FEATURE_MATRIX.md`, `docs/RISKS.md` bila klaim atau status fitur berubah.
5. Jangan memasukkan firmware vendor, APK proprietary, atau log pribadi.
