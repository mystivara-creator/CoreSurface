# Matriks kemampuan dan kebijakan rilis

| Subsystem | Status sebelum modul | Bukti sesudah modul / audit | Status | Aksi |
|---|---|---|---|---|
| WCG / Display P3 | SurfaceFlinger `wide color: 0`, `[0,7]` | `wide color: 1`, `[0,7,9]` | **Exposed (terbukti)** | Tampilkan sebagai fitur preview; verifikasi aplikasi & akurasi terpisah |
| Panel gamut aktual | HWC `wideColorGamut=true`, JSON P3 cocok panel | Tidak ada pengukuran warna | **Belum terukur** | Jangan klaim P3 100% |
| Display Expert Mode | `support_display_expert_mode=false` | Settings memiliki referensi flag | **Kandidat** | Opt-in, hanya A/B |
| Camera HFR | `support_video_hfr_mode=false`, `support_camera_hfr=true` | Camera2 720p120/240; APK punya SlowMotionModule | **Kandidat** | Opt-in, aplikasi dan file video harus diuji |
| DC dimming | Flag Xiaomi campuran | Tidak ada driver/panel test | **Tidak terbukti** | Tidak dipatch |
| Dolby UI | Komponen Dolby ada; Xiaomi `support_dolby=false` | Tidak ada bukti fitur audio hilang | **Tidak terbukti** | Tidak dipatch |
| 4K30 | Camera2 3840×2160 ~33.3ms | Aplikasi mendukung | **Sudah tersedia** | Tidak dipatch |
| 1080p60 | Normal min frame duration ~33.3ms | Tidak ada high-speed 1080p | **Tidak terbukti** | Tidak dipaksa |
| 720p120/240 | Camera2 high-speed ada | App Slow Motion tidak tersedia | **HAL tersedia** | Kandidat HFR UI |
| Vulkan 1.3 / VRS | Driver mengekspose | Tidak ada vendor lock | **Sudah tersedia** | Tidak dipatch |
| HDR / Dolby Vision | Display HAL melaporkan tanpa HDR types | Tidak ada kemampuan terverifikasi | **Tidak didukung pada jalur aktif** | Tidak spoof |
| 120Hz display | Panel 60/90/120 | 60Hz karena mode default | **Normal** | Tidak dipatch |
| Game touch/visual | Game Turbo memiliki kontrol | Sudah ada | **Normal** | Tidak diduplikasi |

**Garis tegas:** status *Exposed* tidak boleh berubah menjadi *Functional* tanpa bukti runtime aplikasi.
