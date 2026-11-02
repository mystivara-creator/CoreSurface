# Kunzite Camera APK: static capability audit

**Perangkat:** Redmi Note 15 5G (`kunzite`), Android 16.  
**Sumber:** `kunzite-camera-audit.tar.gz` yang diberikan pengguna pada 2026-11-02.  
**Metode:** Inspeksi APK/Dalvik DEX dan pembacaan XML secara lokal, **tanpa mengubah file perangkat**.

## Arsip yang diperiksa

- `product/priv-app/MiuiCamera/MiuiCamera.apk` (187.438.435 byte; 7 berkas `classes*.dex`).
- `product/etc/device_features/kunzite.xml` (37.438 byte).
- SHA-256 APK: `d5853285331a7ea5b6c0547d9cf327bb0f60520915cb8acebdfdcc94d9ea0ca1`.

## Bukti utama

| Temuan | Bukti | Interpretasi |
|---|---|---|
| Slow Motion ada dalam APK | `classes2.dex` berisi `com/android/camera/features/mode/slow/SlowMotionModuleEntry`, `com/android/camera/module/video/SlowMotionModule`, antarmuka FPS 120/240, konfigurasi kualitas dan `com.xiaomi.camera.supportedfeatures.CamSupportedSlowMotion` | Kode mode tidak hilang dari APK, **tetapi keberadaan kode tidak membuktikan mode tersedia di perangkat**. |
| Ada gerbang dukungan di runtime | Metode DEX `SlowMotionModuleEntry.support()` menjalankan pemanggilan ke metode yang terobfusikasi (`LG7/b;->L1()`), bukan mengembalikan nilai `true` konstan. | Aktivasi menu memerlukan penelusuran syarat dukungan runtime; membalik satu flag tidak cukup sebagai bukti. |
| Konfigurasi vendor tidak konsisten secara nama | `kunzite.xml`: `support_video_hfr_mode=false` (baris 473), `support_camera_hfr=true` (baris 609), `support_hfr_video_pause=false` (baris 251). | Ketiga flag bisa mengontrol fungsi berbeda. Tidak boleh diasumsikan bahwa salah satunya pasti mengendalikan menu Slow Motion. |
| Tidak ada referensi literal flag di DEX kamera | Nama literal `support_video_hfr_mode` dan `support_camera_hfr` tidak ditemukan dalam ketujuh DEX. | Tidak membuktikan flag tidak dipakai; bisa melalui wrapper/resource/vendor/native atau nama terobfusikasi. Tetapi **belum ada jalur sebab-akibat yang terverifikasi**. |
| Dukungan Camera2 high-speed | Dari log `media.camera` percakapan: 720p 120/240 FPS dan resolusi lebih rendah dilaporkan melalui `availableHighSpeedVideoConfigurations`. | Jalur Camera2 mengekspos mode high-speed; **perekaman dan output Slow Motion Xiaomi belum teruji**. |
| Komponen video lambat | APK memuat `lib/arm64-v8a/libslow_video_color_converter.so`. | Komponen pendukung ada; bukan jaminan mode diregistrasi / kompatibel dengan sensor aktif. |
| 4K aktif | `kunzite.xml`: `support_camera_4k_quality=true` (baris 567); Camera2 mengekspos 3840×2160, durasi minimum ~33,3 ms dari log percakapan. | 4K30 bukan kandidat unlock; kemampuan 1080p60 belum terbukti. |
| Display Expert Mode | `kunzite.xml`: `support_display_expert_mode=false` (baris 396). Hasil pencarian DEX Settings dari percakapan menemukan string flag ini. | Kandidat tampilan yang lebih spesifik untuk **validasi terpisah**; tidak boleh otomatis aktif tanpa validasi alur Settings dan DisplayFeature. |
| DC Dimming | `support_low_flicker_backlight=false`, `support_dc_backlight_sec=true`, `hide_flicker_backlight=true` dalam konfigurasi. | Konfigurasi campuran, tidak membuktikan panel dan driver mendukung DC dimming. |

## Keputusan teknis

1. **Pertahankan:** WCG/P3 yang sudah diekspos ke Android sebagai fitur eksperimen, dengan catatan akurasi gamut fisik belum tervalidasi.
2. **Kandidat, belum layak dipaksa:** `support_display_expert_mode`, menunggu validasi bahwa Settings dan DisplayFeature mampu mengoperasikan seluruh kontrol dengan aman.
3. **Kandidat, belum layak diaktifkan otomatis:** Slow Motion/HFR. Perlu mengidentifikasi pemeriksaan pada `SlowMotionModuleEntry.support()` dan kemampuan per kamera sebelum patch.
4. **Jangan dipaksa:** 1080p60, HDR10/Dolby Vision, DC Dimming, OIS, atau peningkatan sensor tanpa bukti perangkat keras dan HAL.
5. **Modul final:** Satu paket saja, dengan sakelar fitur independen, deteksi kompatibilitas, diagnosis dan rollback. Jangan menambah file modul khusus untuk setiap flag. **Jangan minta pengguna reboot untuk hanya memverifikasi nama flag.**

## Keterbatasan audit

Ini audit statis APK yang diunggah; belum ada trace runtime internal APK, dekompilasi menyeluruh setiap jalur, maupun pengujian perekaman nyata. Beberapa implementasi aplikasi Xiaomi terobfusikasi, dan sebagian keputusan fitur dapat berada dalam dependensi native, konfigurasi cloud, atau layanan lain. Karena itu, **menemukan kode Slow Motion tidak sama dengan membuktikan unlock dapat bekerja**.
