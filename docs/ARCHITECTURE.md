# Arsitektur preview

```text
KernelSU-Next
  └─ kunzite_wcg_probe (ID kompatibel modul WCG lama)
      ├─ customize.sh        → validasi target saat instalasi
      ├─ post-fs-data.sh     → validasi target, WCG resetprop, stage opsi XML
      ├─ service.sh          → penanda boot selesai (bukan daemon kontinu)
      ├─ prepare-overlay.sh  → salinan XML dari baseline lokal yang diverifikasi
      ├─ control.sh          → status dan staging pilihan eksplisit
      ├─ webroot/index.html  → UI status, tidak menjalankan shell sendiri tanpa bridge
      └─ baseline/kunzite.xml → disuntikkan saat build lokal, **bukan di Git**
```

## Model ancaman

- Salah firmware, panel, atau versi XML dapat menyebabkan opsi tidak kompatibel: **gagal tertutup**, jangan ubah ROM lain.
- Installer dan `post-fs-data.sh` memverifikasi SHA-256 XML paket **dan** XML `/product` yang terbaca langsung. Jika berubah, seluruh mutasi modul dilewati dan overlay dihapus saat boot. Ini mencegah penerapan salinan konfigurasi OEM yang basi pada OTA parsial atau konflik overlay.
- Perubahan `ro.surface_flinger.has_wide_color_display` harus dilakukan sejak awal boot; jangan menjanjikan toggle realtime.
- Mount systemless XML bergantung pada KernelSU dan metamodule kompatibel. Kehadiran path `/data/adb/metamodule` bukan bukti mount sukses.
- Staging pada `post-fs-data.sh` perlu pengujian nyata terhadap urutan mount KernelSU. **Lulus pengujian host bukan berarti staging bekerja di perangkat.**
- `boot_pending` dibersihkan setelah `sys.boot_completed=1`; pada boot yang tidak tuntas, percobaan boot berikutnya mencoba mematikan eksperimen. Ini **tidak** menyelamatkan boot pertama; pengguna harus siap recovery.

## Prinsip pembatasan

Satu modul, satu pemilik pengaturan, tidak memodifikasi `/product` secara permanen. WCG aktif hanya jika identitas/ROM sesuai. Expert/HFR default OFF. Tidak mengakali thermal, SELinux, kamera lens ID, EIS/OIS, atau driver Vulkan.

## Pengembangan lanjutan

Jangan ekspor *ready/stable* sebelum berhasil: test systemless mount, app menu, rekaman video, compare konfigurasi, pemulihan setelah reboot, dan pembacaan status UI tanpa false-positive.
