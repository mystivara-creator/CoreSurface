# Changelog

## v0.6.0-preview (2026-11-02) — source snapshot

- Source modular WCG, Expert Mode opt-in, dan Slow Motion HFR opt-in disatukan dalam satu identitas modul.
- Gate perangkat, ROM, panel, dan baseline XML ditambahkan pada source preview.
- WebUI menampilkan property WCG, kemampuan P3, mode aktual dan status eksperimen terpisah.
- Audit capability, Camera APK, risk register, build/rollback disimpan dalam repository.
- **Tidak ada klaim uji perangkat untuk v0.6.0-preview.** Status WCG sudah dibuktikan pada versi modul sebelumnya.

## v0.4.x (historis, 2026-11-02)

- WCG property berhasil dipropagasikan ke Framework/SF dengan mode Display P3 (9).
- Iterasi WebUI v0.4.0 dan hotfix diperlukan karena pembacaan status gagal pada beberapa versi. Status final yang ditampilkan berhasil pada screenshot user.

## v0.1–v0.3 (historis, 2026-11-02)

- Probe WCG read-only/early property untuk panel `p17_41_02_0a`.
- Tidak dianggap rilis stabil.

## Camera HFR probe v0.1.0 (historis)

- Test perubahan `support_video_hfr_mode`, **bukan** bukti Slow Motion berhasil.

## Unreleased: source hardening

- Verify exact OEM XML SHA-256 at installation and early boot before applying any overlays or WCG property.
- Add host integration tests for experimental XML staging and fail-closed behavior.
- Add WebUI bridge regression coverage for synchronous and asynchronous response shapes.
- Extend the source validation gate and test plan; no feature toggles or runtime defaults changed.

- Verify effective Expert/HFR XML after Android boot before clearing rollback marker; report and schedule rollback when systemless mount is missing or partial.
- Exercise the root control shell command with host tests for WCG state, malformed inputs, wrong firmware, and absent metamodule.
- Test post-boot verification with synthetic mounted-XML fixtures, including partial/missing mounts. No additional device writes or default feature changes.
- Prevent WebUI toggles from rewriting/deleting potentially live mounted overlay backing files; prepare the new configuration only before the next KernelSU mount.

## v0.6.1-preview (unreleased)

- Correct KernelSU meta-overlayfs content location: dedicated `product` partition in metamodule ext4 image, rather than metadata `system/product` folder.
- Stage XML before metamodule mount, verify byte-for-byte and retain `skip_mount` on failure.
- Require `meta-overlayfs` by ID for Expert/HFR instead of assuming any metamodule can mount dynamic XML.
- Preserve WCG property path unchanged; no change to experimental defaults.

## v0.6.2-preview (CI artifact)

- CI builds a reproducible KernelSU ZIP and uploads it with SHA-256 checksum.
- No Xiaomi proprietary XML is included: installer captures and validates the on-device baseline during installation.
- Added install-time checksum and artifact integrity regression tests. Experimental toggles remain OFF.
