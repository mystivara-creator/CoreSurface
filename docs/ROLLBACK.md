# Rollback dan pemulihan

- **Pilihan eksperimen OFF:** Nonaktifkan Expert/HFR pada WebUI. Efek overlay baru terangkat pada reboot berikutnya; jangan klaim langsung pulih realtime.
- **Masalah display warna:** Nonaktifkan modul WCG dari KernelSU-Next, lalu reboot untuk kembali ke konfigurasi bawaan.
- **Boot bermasalah:** Nonaktifkan modul dengan recovery/KernelSU safe mode menggunakan prosedur yang sudah dikuasai. Jangan menunggu mekanisme automatic rollback bila perangkat tidak bisa boot pertama.
- **Pembaruan ROM:** Nonaktifkan modul sebelum update; audit ulang fingerprint dan XML lalu buat build sesuai sumber baru.
- **Konflik:** Jangan hidupkan modul HFR lama bersamaan dengan suite. ID modul WCG dipertahankan supaya tidak terjadi duplikasi properti.

Firmware asli `/product/etc/device_features/kunzite.xml` **tidak diubah in-place** oleh source ini. Backup penuh tetap disarankan.
