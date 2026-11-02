# Risk register (preview)

| Risiko | Severity | Pencegahan / mitigasi | Status |
|---|---|---|---|
| Salah ROM/panel | Tinggi | Checks di instalasi dan boot; checksum XML lokal | Host validation only |
| KernelSU systemless overlay tidak masuk | Tinggi | Metamodule required; cek XML runtime setelah boot | Belum terbukti pada perangkat |
| Bootloop akibat modifikasi XML | Tinggi | Experimental OFF; backup/recovery; boot marker | Belum live-tested |
| WCG tersedia tapi warna salah | Sedang | Jangan paksa P3 global; uji aplikasi/kalibrasi | Exposed only |
| HFR toggle tidak memunculkan menu | Sedang | Jangan klaim true unlock, identifikasi runtime gate APK | Belum diuji |
| Settings expert mode crash | Sedang | Default OFF, rollback mudah | Belum diuji |
| Data audit pribadi terbuka | Tinggi | Hanya ringkasan sanitized, tidak upload full raw log/APK | Dijaga |
| UI salah baca status | Sedang | Bedakan status property, exposed, runtime, tested | Masih butuh device acceptance |

Tidak boleh menambah fitur baru sebelum risiko dasar ini dievaluasi.
