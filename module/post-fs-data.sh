#!/system/bin/sh
# Early property application. Optional XML overlay is staged before metamodule mount.
M=${0%/*}
# Slow Motion is already present in stock Camera; discard legacy HFR requests.
rm -f "$M/hfr_enabled"
ROM=$(getprop ro.system.build.version.incremental)
if [ "$(getprop ro.product.device)" != kunzite ] || [ "$(getprop ro.board.platform)" != parrot ] || [ "$ROM" != 16OS3.1.260918.151434134.QCPEGL.S ]; then
  : > "$M/skip_mount"
  rm -rf "$M/product" "$M/system"
  echo 'DISABLED: firmware/device compatibility mismatch' > "$M/boot_result.txt"
  exit 0
fi
PANEL=/sys/devices/virtual/mi_display/disp_feature/disp-DSI-0/panel_info
if [ -r "$PANEL" ]; then
  NAME=$(sed -n 's/^panel_name=//p' "$PANEL" | head -n 1)
  if [ -n "$NAME" ] && [ "$NAME" != mdss_dsi_p17_41_02_0a_amoled_dsc_vid ]; then
    : > "$M/skip_mount"
    rm -rf "$M/product" "$M/system"
    echo 'DISABLED: unsupported panel' > "$M/boot_result.txt"
    exit 0
  fi
fi
# Reject changed or spoofed OEM features without mounting stale experimental XML.
# Hash *both* the packaged baseline and the unmapped live /product file at early boot.
AUDITED_XML_SHA=3b434af171d5d14d1a7c4fa40097dc5c6a5b19e8e4dd0515c37a38d23d3fd48f
BASE="$M/baseline/kunzite.xml"
STOCK_XML=/product/etc/device_features/kunzite.xml
if [ ! -r "$STOCK_XML" ] || [ ! -r "$BASE" ] || \
   [ "$(sha256sum "$BASE" 2>/dev/null | cut -d ' ' -f 1)" != "$AUDITED_XML_SHA" ] || \
   [ "$(sha256sum "$STOCK_XML" 2>/dev/null | cut -d ' ' -f 1)" != "$AUDITED_XML_SHA" ]; then
  : > "$M/skip_mount"
  rm -rf "$M/product" "$M/system"
  rm -f "$M/expert_enabled" "$M/hfr_enabled" "$M/boot_pending"
  echo 'DISABLED: OEM feature XML checksum mismatch; no property or overlay applied' > "$M/boot_result.txt"
  exit 0
fi
# If experimental mode stopped previous boot completing, revert its XML on next attempt.
if [ -f "$M/boot_pending" ]; then
  rm -f "$M/expert_enabled" "$M/hfr_enabled" "$M/boot_pending"
  : > "$M/skip_mount"
  rm -rf "$M/product" "$M/system"
  echo 'AUTO_ROLLBACK: unfinished experimental boot' > "$M/recovery_reason"
fi
if [ -f "$M/expert_enabled" ]; then
  if [ ! -r /data/adb/metamodule/module.prop ] || ! grep -qx 'id=meta-overlayfs' /data/adb/metamodule/module.prop; then
    : > "$M/skip_mount"
    rm -rf "$M/product" "$M/system"
    echo 'EXPERIMENTS_SKIPPED: compatible meta-overlayfs unavailable' > "$M/boot_result.txt"
  elif /system/bin/sh "$M/prepare-overlay.sh" && /system/bin/sh "$M/stage-meta-overlayfs.sh"; then
    : > "$M/boot_pending"
    echo 'EXPERIMENTS_STAGED: staged into meta-overlayfs ext4 image; awaiting mount and app validation' > "$M/boot_result.txt"
  else
    : > "$M/skip_mount"
    rm -rf "$M/product" "$M/system"
    rm -f "$M/expert_enabled" "$M/hfr_enabled"
    echo 'EXPERIMENTS_SKIPPED: staging or meta-overlayfs validation failed' > "$M/boot_result.txt"
  fi
else
  : > "$M/skip_mount"
  rm -rf "$M/product" "$M/system"
  echo 'WCG_ONLY: experimental flags disabled' > "$M/boot_result.txt"
fi
if [ ! -f "$M/wcg_disabled" ]; then
  if command -v resetprop >/dev/null 2>&1; then
    resetprop -n ro.surface_flinger.has_wide_color_display true
    if [ "$(getprop ro.surface_flinger.has_wide_color_display)" = true ]; then
      echo 'WCG_PROPERTY_APPLIED: P3 gamut accuracy not validated' >> "$M/boot_result.txt"
    else
      echo 'WCG_PROPERTY_FAILED' >> "$M/boot_result.txt"
    fi
  else
    echo 'WCG_PROPERTY_SKIPPED: resetprop missing' >> "$M/boot_result.txt"
  fi
fi
