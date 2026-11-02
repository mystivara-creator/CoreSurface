#!/system/bin/sh
# Early property application. Optional XML overlay is staged before metamodule mount.
M=${0%/*}
ROM=$(getprop ro.system.build.version.incremental)
if [ "$(getprop ro.product.device)" != kunzite ] || [ "$(getprop ro.board.platform)" != parrot ] || [ "$ROM" != 16OS3.1.260918.151434134.QCPEGL.S ]; then
  : > "$M/skip_mount"
  rm -rf "$M/system"
  echo 'DISABLED: firmware/device compatibility mismatch' > "$M/boot_result.txt"
  exit 0
fi
PANEL=/sys/devices/virtual/mi_display/disp_feature/disp-DSI-0/panel_info
if [ -r "$PANEL" ]; then
  NAME=$(sed -n 's/^panel_name=//p' "$PANEL" | head -n 1)
  if [ -n "$NAME" ] && [ "$NAME" != mdss_dsi_p17_41_02_0a_amoled_dsc_vid ]; then
    : > "$M/skip_mount"
    rm -rf "$M/system"
    echo 'DISABLED: unsupported panel' > "$M/boot_result.txt"
    exit 0
  fi
fi
# If experimental mode stopped previous boot completing, revert its XML on next attempt.
if [ -f "$M/boot_pending" ]; then
  rm -f "$M/expert_enabled" "$M/hfr_enabled" "$M/boot_pending"
  : > "$M/skip_mount"
  rm -rf "$M/system"
  echo 'AUTO_ROLLBACK: unfinished experimental boot' > "$M/recovery_reason"
fi
if [ -f "$M/expert_enabled" ] || [ -f "$M/hfr_enabled" ]; then
  if [ ! -e /data/adb/metamodule ]; then
    : > "$M/skip_mount"
    rm -rf "$M/system"
    echo 'EXPERIMENTS_SKIPPED: metamodule unavailable' > "$M/boot_result.txt"
  elif /system/bin/sh "$M/prepare-overlay.sh"; then
    : > "$M/boot_pending"
    echo 'EXPERIMENTS_STAGED: awaiting mount and app validation' > "$M/boot_result.txt"
  else
    : > "$M/skip_mount"
    rm -rf "$M/system"
    rm -f "$M/expert_enabled" "$M/hfr_enabled"
    echo 'EXPERIMENTS_SKIPPED: overlay validation failed' > "$M/boot_result.txt"
  fi
else
  : > "$M/skip_mount"
  rm -rf "$M/system"
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
