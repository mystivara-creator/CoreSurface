#!/system/bin/sh
# KernelSU-Next sources this script in its installer shell; never set -e/-u.
# Global shell options would break KernelSU's set_perm optional $5 argument
# and can terminate installation before our own messages are printed.
ui_print '- Validating Kunzite firmware and preparing private OEM baseline'
# Installation is device / firmware locked. No changes are made to stock partitions.
[ "$(getprop ro.product.device)" = kunzite ] || abort 'Only Redmi Note 15 5G / kunzite is supported'
[ "$(getprop ro.board.platform)" = parrot ] || abort 'Unsupported board'
ROM=$(getprop ro.system.build.version.incremental)
[ "$ROM" = 16OS3.1.260918.151434134.QCPEGL.S ] || abort "ROM not audited: $ROM"
PANEL=/sys/devices/virtual/mi_display/disp_feature/disp-DSI-0/panel_info
if [ -r "$PANEL" ]; then
  NAME=$(sed -n 's/^panel_name=//p' "$PANEL" | head -n 1)
  [ "$NAME" = mdss_dsi_p17_41_02_0a_amoled_dsc_vid ] || abort "Panel not audited: $NAME"
fi
# Build artifacts intentionally omit OEM XML. Capture only audited stock on install.
AUDITED_XML_SHA=3b434af171d5d14d1a7c4fa40097dc5c6a5b19e8e4dd0515c37a38d23d3fd48f
STOCK_XML=/product/etc/device_features/kunzite.xml
BASE="$MODPATH/baseline/kunzite.xml"
[ -r "$STOCK_XML" ] || abort 'Cannot read live product feature XML'
[ "$(sha256sum "$STOCK_XML" | cut -d ' ' -f 1)" = "$AUDITED_XML_SHA" ] || abort 'Live product XML differs from audited firmware; disable conflicting overlays or re-audit ROM'
if [ ! -s "$BASE" ]; then
  mkdir -p "$MODPATH/baseline" || abort 'Cannot create private XML baseline directory'
  TMP="$MODPATH/baseline/.kunzite.xml.$"
  cp "$STOCK_XML" "$TMP" || abort 'Cannot copy audited device feature XML'
  if [ "$(sha256sum "$TMP" | cut -d ' ' -f 1)" != "$AUDITED_XML_SHA" ]; then
    rm -f "$TMP"
    abort 'Device feature XML changed while being copied'
  fi
  chmod 0644 "$TMP" || abort "Cannot set permissions on private XML baseline"
  mv -f "$TMP" "$BASE" || abort 'Cannot store verified baseline'
fi
[ "$(sha256sum "$BASE" | cut -d ' ' -f 1)" = "$AUDITED_XML_SHA" ] || abort 'Existing XML baseline differs from audited firmware'
[ "$(grep -o '<bool name="support_video_hfr_mode">false</bool>' "$MODPATH/baseline/kunzite.xml" | wc -l)" -eq 1 ] || abort 'Baseline HFR flag invalid'
[ "$(grep -o '<bool name="support_display_expert_mode">false</bool>' "$MODPATH/baseline/kunzite.xml" | wc -l)" -eq 1 ] || abort 'Baseline Expert flag invalid'
# Upgrade under the existing WCG module ID. Drop stale 0.5.0 overlays and one-shot flags.
rm -rf "$MODPATH/product" "$MODPATH/system" "$MODPATH/arm_once" "$MODPATH/one_boot_pending" "$MODPATH/boot_pending" 2>/dev/null || true
rm -f "$MODPATH/skip_mount" "$MODPATH/expert_enabled" "$MODPATH/hfr_enabled" "$MODPATH/recovery_reason" 2>/dev/null || true
: > "$MODPATH/skip_mount"
# Keep previously selected WCG enable/disable preference where present.
# Do not carry HFR or Expert from older experimental modules into the new version.
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755 || abort 'Cannot set post-fs-data permissions'
set_perm "$MODPATH/service.sh" 0 0 0755 || abort 'Cannot set service permissions'
set_perm "$MODPATH/control.sh" 0 0 0755 || abort 'Cannot set control permissions'
set_perm "$MODPATH/prepare-overlay.sh" 0 0 0755 || abort 'Cannot set overlay permissions'
set_perm "$MODPATH/stage-meta-overlayfs.sh" 0 0 0755 || abort 'Cannot set staging permissions'
ui_print '- One module: existing WCG module will be updated'
ui_print '- WCG: existing exposure retained'
ui_print '- Expert and Slow Motion: experimental, OFF by default'
ui_print '- Systemless XML overlay only after explicit opt-in and meta-overlayfs metamodule'
ui_print '- No HDR, 1080p60, overclock or thermal bypass'
if [ -d /data/adb/modules/kunzite_hfr_probe ] && [ ! -f /data/adb/modules/kunzite_hfr_probe/disable ]; then
  ui_print '! Standalone HFR module detected: disable it before using HFR in this suite'
fi
