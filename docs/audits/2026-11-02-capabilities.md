# Kunzite Capability Audit — Baseline 2026-11-02

**Perangkat:** Redmi Note 15 5G (`kunzite`, platform `parrot`), Android 16.  
**Sumber lokal:** arsip `kunzite-audit.tar.gz` berisi 11 berkas audit, termasuk `properties.txt`, `camera.txt`, `codecs.txt`, `display.txt`, `graphics.txt`, `services.txt`, `features.txt`, `/product/etc/device_features/kunzite.xml`, konfigurasi Camera HAL/EIS, dan JSON kalibrasi panel.  
**Metode:** analisis baca-saja. **Tidak ada modifikasi firmware, instalasi modul, atau reboot.**

## Hasil utama

| Area | Bukti di arsip | Penilaian | Tindakan untuk paket akhir |
|---|---|---|---|
| Wide Color Gamut | `ro.surface_flinger.has_wide_color_display=true` saat modul aktif; SurfaceFlinger WCG=1, modes `NATIVE`, `SRGB`, `DISPLAY_P3`; `dumpsys display` mode `[0,7,9]`; HWC WCG=true; panel aktif `p17_41_02_0a` mempunyai profil kalibrasi P3 | **Terbukti terekspos ke Android**; rendering konten P3 dan akurasi warna fisik belum diukur | Pertahankan sebagai satu-satunya perubahan default yang punya hasil A/B nyata; jangan paksa mode P3 global |
| Xiaomi Display Expert Mode | `support_display_expert_mode=false`; di file yang sama `expert_gamut_min=0`, `expert_gamut_max=3`, serta rentang RGB, gamma, contrast, hue, saturation | **Kandidat pembatasan antarmuka yang kuat**, tetapi rentang parameter tidak membuktikan UI/layanan dapat menggunakannya | Implementasi *eksperimental*, default **OFF** sampai rute Settings/DisplayFeature tervalidasi |
| Kamera Slow Motion / HFR | `support_video_hfr_mode=false` tetapi `support_camera_hfr=true`; metadata Camera2 kamera belakang ID 0/4 mengekspos 720p120 dan 720p240; pengguna menyatakan menu Slow Motion tidak tersedia | **Kandidat pembatasan antarmuka yang kuat** dengan kemampuan high-speed HAL terbukti; flag saja belum cukup | Boleh menguji akses UI secara systemless, tetapi tidak menjanjikan menu muncul atau rekaman berfungsi |
| Pengaturan DC dimming/flicker | `support_low_flicker_backlight=false`, `support_dc_backlight_sec=true`, `hide_flicker_backlight=true` | **Kandidat investigasi**, belum ada bukti jalur panel mendukung DC dimming dengan aman | Jangan diaktifkan default; perlu pembuktian kompatibilitas panel dan efek pada PWM/kecerahan |
| Dolby Audio | `support_dolby=false` pada Xiaomi device feature; `ro.vendor.audio.dolby.dax.support=true`, `ro.vendor.audio.dolby.surround.enable=true`, DAX3 terdeteksi, service `vendor.dolby.dms.IDms/default` tersedia, codec AC3/EAC3/AC4 terdaftar | **Ketidaksesuaian kebijakan/UI dengan komponen audio**; tidak berarti Dolby Processing tidak aktif atau bisa dibuka lebih jauh | Pemeriksaan status saja; jangan spoof lisensi atau memodifikasi audio chain sebelum ada bukti |
| Kamera 4K | Kamera 0/4 menawarkan output 3840×2160, min frame duration 33.333.333 ns (~30 FPS); `support_camera_4k_quality=true` | **Sudah tersedia** | Bukan kandidat unlock |
| 1080p60 | Min frame duration video biasa 1920×1080 ~33,3 ms (~30 FPS), AE target normal sampai 30 FPS; high-speed configs tidak mencantumkan 1080p | **Belum didukung jalur yang diumumkan HAL**; tidak boleh disimpulkan bisa dibuka hanya karena encoder lebih cepat | Jangan aktifkan / jangan klaim 1080p60 |
| Stabilisasi | `android.control.availableVideoStabilizationModes=[0,1]`; Camera HAL `isVideoStabilizationPreviewSupported=1`; lensa semua camera ID melaporkan `availableOpticalStabilization=[0]` | **Stabilisasi video tersedia; OIS hardware tidak dilaporkan lewat Camera2**. `EISv2DisableOIS=0` bukan bukti OIS terpasang | Jangan memaksa OIS |
| Codec video | Qualcomm AVC/HEVC encode/decode hardware tersedia; HEVC decoder Main10 (10-bit), HEVC encoder Main; AV1 software decoder | **Sudah didukung sesuai daftar codec**, tidak ada bukti fitur terkunci | Tidak perlu patch codec |
| HDR display / Dolby Vision | `ro.surface_flinger.has_HDR_display=false`; HWC `hdr10=false`, `hlg=false`, `dv=false`; `supportedHdrTypes=[]`. JSON panel mempunyai nama profil `standard_hdr` tetapi HAL tidak mengekspos HDR | **Belum didukung jalur display aktif** | Jangan spoof HDR/Dolby Vision; berisiko rendering salah |
| GPU/Vulkan | Vulkan API 1.3 terdeklarasi (`android.hardware.vulkan.version=4206592`); Adreno 710 / VRS dari audit sebelumnya. Qualcomm GPU freq table normal 295–940 MHz. | **Kemampuan sudah diekspos**, tidak ada bukti batasan frekuensi vendor terselubung | Jangan overclock, spoof ray tracing/mesh shader, atau tambah tweak performa |
| Refresh rate | Panel mode 60/90/120 Hz. Pengguna memilih mode default; MIUI dapat memilih 60 Hz secara dinamis | **Normal sesuai pengaturan** | Bukan kandidat unlock |
| Game Turbo / touch | Layanan Joyose, MiuiBooster, TouchFeature, Game Turbo; screenshot sebelumnya menunjukkan pengaturan respons sentuhan dan visual | **Fitur pengguna sudah ada**, tidak ada bukti lock hardware | Jangan duplikasi |

## Detail kamera yang relevan

Dari metadata Camera2, *back camera* ID **0** dan **4** mencantumkan high-speed `1280×720` pada 120 dan 240 FPS; beberapa kamera depan mencantumkan `1280×720` pada 120 FPS. Ini merupakan **dukungan HAL untuk sesi constrained high-speed**, bukan dukungan aplikasi Kamera bawaan. Rekomendasi fitur slow-motion adalah 720p120/240, *bukan* 1080p60. Sensor utama teridentifikasi dari `persist.vendor.camera.mi.module.info` sebagai `p17_sunny_s5khm9_main_i`; jangan menyimpulkan semua library vendor sensor aktif sekaligus.

## Display Expert Mode

`/product/etc/device_features/kunzite.xml` memuat `support_display_expert_mode=false`, tetapi mempunyai rentang `expert_gamut_max=3`, RGB 50–255, hue -180–180, saturation -50–50, gamma 170–270, dan contrast -100–100. Ini kandidat **menu Xiaomi** yang lebih spesifik daripada membuat menu P3 fiktif. Sebelum mengaktifkannya, implementasi harus membuktikan pemakaian flag ini oleh Settings/DisplayFeature dan ketersediaan kalibrasi yang aman. Jangan menulis nilai kalibrasi arbitrer.

## WCG yang sudah bekerja

Panel fisik yang dilaporkan sebelumnya ialah `mdss_dsi_p17_41_02_0a_amoled_dsc_vid`, cocok dengan JSON kalibrasi. Profil `standard_P3`, `hal_dcip3`, `standard_sRGB` tersedia. Arsip diambil **saat modul WCG aktif**, maka `has_wide_color_display=true` bukan nilai baseline stock. Pada baseline stock sebelumnya properti `false` dan mode P3 difilter. Sekarang Android mengenali P3 namun *current color mode* `SRGB(7)`; sRGB sebagai mode idle/default normal. Nama `standard_hdr` dalam JSON tidak mengubah ketiadaan HDR di HWC.

## Implementasi paket final yang disarankan

- **Satu modul KernelSU** dengan ID dan jalur migrasi yang jelas dari modul WCG saat ini. Jangan menyisakan dua modul yang memasang overlay pada file yang sama.
- **WCG**: tersedia sebagai opsi terverifikasi tingkat framework; default aktif hanya pada panel kunzite yang cocok dan hanya setelah proteksi kompatibilitas lolos. Jangan paksa P3 global.
- **HFR 720p** dan **Xiaomi Display Expert Mode**: ditandai *experimental* dan default nonaktif. WebUI harus membedakan `flag set`, `layanan menerima`, `opsi muncul di UI`, dan `perekaman/rendering berhasil`.
- **DC dimming** dan **Dolby UI**: observasi / informasi saja sampai ada bukti fungsi hardware dan entitlement yang relevan.
- **Tidak termasuk**: 1080p60 tanpa dukungan kamera HAL, HDR/Dolby Vision tanpa HWC, OIS tanpa sensor, ray tracing/mesh shader yang tak didukung, tweak frekuensi/thermal.
- **Teknis**: deteksi perangkat dan panel, cek metadata versi ROM, dukungan mount systemless (gagal tertutup jika tidak ada), backup/rollback, tidak ada daemon polling agresif, logging per fitur, tidak mematikan SELinux atau thermal, pengaturan eksperimen independen, dan WebUI yang memisahkan `tersedia`, `aktif`, `berhasil terverifikasi`.
- **Pengujian sebelum rilis**: validasi ZIP + shell + WebUI statis, pemeriksaan XML yang dimodifikasi, rollback dan toleransi boot failure, kesesuaian pada ROM kunzite yang sedang terpasang. Mengaktifkan HFR tetap butuh uji nyata pada aplikasi kamera dan hasil video; pengujian offline tidak dapat menggantikannya.

## Batas audit

Arsip tidak mencakup kode `Settings.apk`, `Camera.apk`, implementasi `DisplayFeature` dan `TouchFeature` vendor, ataupun metadata driver GPU lengkap. Karena itu **belum dapat dibuktikan** apakah hanya mengubah boolean di `kunzite.xml` bisa mengaktifkan menu Expert Mode/Slow Motion. Tidak sah mengklaim fitur selesai tanpa pengujian pengguna. Sudah cukup bukti untuk menetapkan ruang lingkup modul dan menolak fitur yang jelas tidak didukung; tidak cukup untuk menjamin seluruh fitur eksperimental bekerja.

## Referensi kode Android

- AOSP SurfaceFlinger Properties: https://source.android.com/docs/core/graphics/surfaceflinger-props
- AOSP SurfaceFlinger color-mode filtering: https://chromium.googlesource.com/aosp/platform/frameworks/native/+/refs/heads/master/services/surfaceflinger/SurfaceFlinger.cpp
- Android Camera2 high speed sessions: https://developer.android.com/reference/android/hardware/camera2/CameraDevice

*Catatan privasi: laporan ini sengaja tidak menyertakan data identitas hardware unik dari `properties.txt`.*
