# Roadmap

- [x] Audit Android 16/HyperOS perangkat (`kunzite`/`parrot`).
- [x] Validasi P3 terekspos sampai Framework sesudah WCG module.
- [x] Kumpulkan dan audit APK MiuiCamera (DEX) dan konfigurasi kamera.
- [x] Simpan temuan dalam format dokumentasi berversi.
- [x] Source preview tunggal: WCG + flag Expert/HFR opt-in.
- [ ] Validasi runtime KernelSU mount, kompatibilitas metamodule, dan pemulihan.
- [ ] Validasi menu Expert Mode dan interaksi DisplayFeature secara nyata.
- [ ] Temukan jalur gate `SlowMotionModuleEntry.support()` sampai penyebab mode tersembunyi.
- [ ] Validasi Slow Motion benar-benar merekam dan metadata fps sesuai.
- [ ] Validasi rendering P3 dan, jika memungkinkan, akurasi panel.
- [ ] Dokumentasi reproducible A/B, hasil uji kompatibilitas OTA/region.
- [ ] Release stabil hanya sesudah acceptance test lolos.

## Koreksi prioritas

- HFR unlock dibatalkan karena menu Slow Motion sudah tersedia secara bawaan. Tidak perlu reboot atau perubahan kamera untuk fitur tersebut.
- Prioritas berikutnya: memastikan WebUI membaca status penuh dan menguji Expert Mode sendiri dengan rencana rollback.
