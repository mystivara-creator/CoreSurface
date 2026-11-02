# Kunzite Capability Suite v0.6.2-preview

Target device: Redmi Note 15 5G (`kunzite`, `parrot`). ROM: `16OS3.1.260918.151434134.QCPEGL.S`, panel `mdss_dsi_p17_41_02_0a_amoled_dsc_vid`. Installer fails closed on mismatch.

**Existing module ID:** `kunzite_wcg_probe`. Updates existing WCG module in place. Do not install an independent HFR probe at the same time.

## Features

- **WCG**: Enabled by default unless previous WCG module was disabled. `resetprop -n ro.surface_flinger.has_wide_color_display true` during early boot. Evidence: Android exposes `DISPLAY_P3 (9)` when active on user ROM. No global P3 forcing; gamut accuracy unverified.
- **Xiaomi Expert Mode**: OFF by default. Opt-in systemless XML overlay modifies *only* `support_display_expert_mode=false` to `true`. UI controls not proven operational.
- **Camera HFR / Slow Motion**: OFF by default. Opt-in overlay changes *only* `support_video_hfr_mode=false` to `true`. Camera2 advertises 720p120/240; Xiaomi Camera's mode gate is more complex and **menu not guaranteed**.
- **No hacks**: No HDR/Dolby Vision spoof, 1080p60, overclock, thermal bypass, or lens spoofing. No background polling daemon.

## Compatibility and safety

- `baseline/kunzite.xml` is captured during installation from the audited device firmware (SHA-256 `3b434af171d5d14d1a7c4fa40097dc5c6a5b19e8e4dd0515c37a38d23d3fd48f`). Experimental overlay is generated only when opted in.
- KernelSU systemless file overlays require an installed meta-overlayfs metamodule. Without one, WCG can run, Expert/HFR toggles are blocked.
- The module uses `skip_mount` and no `system` overlay by default, avoiding unnecessary changes to device XML. Changes to staged XML become effective after one reboot.
- On mismatch, the module skips changes. With optional experimental flags, a boot marker is removed after boot completion; if a boot attempt cannot complete, the next boot attempt automatically disables experimental flags. This does **not** replace recovery backup; if first boot is stuck, disable the module in recovery.
- Dynamic WebUI (KernelSU bridge) reports effective property vs upcoming settings, P3 availability, actual color mode, and experimental flags separately. A true XML flag does **not** confirm UI menu or capture success.

## Rollback

Disable the module in KernelSU-Next and reboot. The original firmware files are never overwritten. If the optional experiments fail but boot succeeds, switch them OFF in the WebUI and reboot once to undo the overlay.

## Installation

Install one ZIP via KernelSU-Next, replacing existing `kunzite_wcg_probe`. Reboot once. To avoid additional reboots, choose experimental options only when ready to test; these experiments are not enabled automatically. If there is an old `kunzite_hfr_probe` standalone module, disable it before enabling HFR in this suite.

## Evidence levels

| Feature | Status |
|---|---|
| WCG property + P3 mode exposure | Verified at Framework level |
| Display P3 physical color accuracy | Unverified |
| Expert Mode UI and DisplayFeature behavior | Unverified |
| HFR feature flag | Testable, but not proven to unlock Xiaomi Slow Motion |
| Slow Motion recording | Unverified |

## Penting: penyimpanan metamodule

meta-overlayfs menyimpan payload partisi pada ext4 image (`/data/adb/metamodule/mnt/<module_id>/product`), bukan di `$MODPATH/system`. Pada boot, suite memasang image lebih awal selama `post-fs-data` (sebelum `metamount.sh`), menyalin XML yang diverifikasi dan **baru melepas `skip_mount` setelah file cocok**. Pengujian host tidak menjamin mount berhasil pada perangkat; jika staging gagal, WCG tetap bisa diterapkan tanpa overlay eksperimen. Hanya meta-overlayfs yang didukung untuk dua eksperimen ini, bukan metamodule generik.

## GitHub Actions artifact

The CI ZIP contains no Xiaomi proprietary XML. During install, `customize.sh` verifies device, ROM, panel and stock XML SHA-256, then stores the baseline privately inside the installed module. Both experiments remain OFF. Artifacts are previews, not stable releases.
