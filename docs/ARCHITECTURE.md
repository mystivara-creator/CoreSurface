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
      └─ baseline/kunzite.xml → ditangkap saat instalasi dari device, bukan di ZIP/Git
```

## Model ancaman

- Salah firmware, panel, atau versi XML dapat menyebabkan opsi tidak kompatibel: **gagal tertutup**, jangan ubah ROM lain.
- Installer memvalidasi XML asli dan menyimpan baseline privat; `post-fs-data.sh` memverifikasi SHA-256 baseline dan XML `/product` yang terbaca langsung. Jika berubah, seluruh mutasi modul dilewati dan overlay dihapus saat boot. Ini mencegah penerapan salinan konfigurasi OEM yang basi pada OTA parsial atau konflik overlay.
- Perubahan `ro.surface_flinger.has_wide_color_display` harus dilakukan sejak awal boot; jangan menjanjikan toggle realtime.
- Mount systemless XML bergantung pada KernelSU dan metamodule kompatibel. Kehadiran path `/data/adb/metamodule` bukan bukti mount sukses.
- Staging pada `post-fs-data.sh` perlu pengujian nyata terhadap urutan mount KernelSU. **Lulus pengujian host bukan berarti staging bekerja di perangkat.**
- `boot_pending` dibersihkan setelah `sys.boot_completed=1`; pada boot yang tidak tuntas, percobaan boot berikutnya mencoba mematikan eksperimen. Ini **tidak** menyelamatkan boot pertama; pengguna harus siap recovery.

## Prinsip pembatasan

Satu modul, satu pemilik pengaturan, tidak memodifikasi `/product` secara permanen. WCG aktif hanya jika identitas/ROM sesuai. Expert default OFF. Tidak mengakali thermal, SELinux, kamera lens ID, EIS/OIS, atau driver Vulkan.

## Pengembangan lanjutan

Jangan ekspor *ready/stable* sebelum berhasil: test systemless mount, app menu, rekaman video, compare konfigurasi, pemulihan setelah reboot, dan pembacaan status UI tanpa false-positive.

## Perubahan konfigurasi runtime

WebUI hanya menyimpan pilihan flag eksperimen; tidak membuat atau menghapus berkas overlay ketika Android sudah berjalan. `post-fs-data.sh` menyiapkan XML yang telah diverifikasi di **ext4 image meta-overlayfs** sebelum `metamount.sh` milik KernelSU. `service.sh` kemudian mengecek nilai flag pada `/product` yang benar-benar ter-mount setelah boot. Ketidakcocokan mempertahankan marker rollback untuk startup berikutnya, tidak melakukan unmount agresif saat berjalan.

## Perbaikan lokasi overlay (v0.6.1-preview)

Pada meta-overlayfs v1.3.x, `modules.img` menyimpan konten di `/data/adb/metamodule/mnt/<module_id>/product/...`; hanya metadata/flag yang ada di `/data/adb/modules/<module_id>`. Membuat `$MODPATH/system/product/...` saat boot tidak bisa diandalkan karena payload itu bukan sumber mount. Kini kami membuat XML minimal pada staging privat modul, memasang image meta-overlayfs sebelum `metamount.sh`, menyalin ke path partisi `product` dalam image, memverifikasi kesesuaian, dan membuang `skip_mount` **hanya setelah** salinan selesai. Jika sumber tidak cocok, mount tidak dilakukan. Dinamis tanpa menyentuh `/product` asli; efek baru berlaku pada boot setelah tombol di WebUI ditekan.
