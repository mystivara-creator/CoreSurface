#!/system/bin/sh
# Root-only status and staged feature toggles for KernelSU WebUI.
set -eu
M=${0%/*}
ROM_EXPECT=16OS3.1.260918.151434134.QCPEGL.S
panel_path=/sys/devices/virtual/mi_display/disp_feature/disp-DSI-0/panel_info
one_line() { printf '%s\n' "$1" | tr '\r\n' '  '; echo; }
flag(){ [ -f "$M/$1" ] && echo on || echo off; }
compat(){ [ "$(getprop ro.product.device)" = kunzite ] && [ "$(getprop ro.board.platform)" = parrot ] && [ "$(getprop ro.system.build.version.incremental)" = "$ROM_EXPECT" ]; }
status() {
  if compat; then echo 'device=compatible'; else echo 'device=unsupported_or_updated'; fi
  echo "wcg_next=$( [ -f "$M/wcg_disabled" ] && echo off || echo on )"
  echo "wcg_property=$(getprop ro.surface_flinger.has_wide_color_display)"
  echo "expert_next=$(flag expert_enabled)"
  if [ -r /data/adb/metamodule/module.prop ] && grep -qx 'id=meta-overlayfs' /data/adb/metamodule/module.prop; then echo 'metamodule=meta-overlayfs'; else echo 'metamodule=missing_or_unsupported'; fi
  if [ -r /product/etc/device_features/kunzite.xml ]; then
    XML=/product/etc/device_features/kunzite.xml
    for item in 'support_display_expert_mode expert_runtime' 'support_video_hfr_mode hfr_runtime'; do
      set -- $item
      if grep -Fq "<bool name=\"$1\">true</bool>" "$XML"; then echo "$2=true"
      elif grep -Fq "<bool name=\"$1\">false</bool>" "$XML"; then echo "$2=false"
      else echo "$2=unknown"; fi
    done
  else
    echo 'expert_runtime=unavailable'
    echo 'hfr_runtime=unavailable'
  fi
  if [ -r "$panel_path" ]; then
    sed -n 's/^panel_name=/panel=/p' "$panel_path" | head -n 1
  fi
  TMP=/data/local/tmp/kunzite-suite-sf.$$
  if dumpsys SurfaceFlinger > "$TMP" 2>/dev/null; then
    sed -n 's/^Device supports wide color: /sf_wcg=/p' "$TMP" | head -n 1
    if grep -q 'ColorMode::DISPLAY_P3 (9)' "$TMP"; then echo 'p3_available=yes'; else echo 'p3_available=no'; fi
    sed -n 's/^[[:space:]]*Current color mode: /active_color=/p' "$TMP" | head -n 1
  else
    echo 'sf_wcg=unavailable'
    echo 'p3_available=unavailable'
  fi
  rm -f "$TMP"
  [ -f "$M/boot_result.txt" ] && { echo 'boot_log_start'; cat "$M/boot_result.txt"; echo 'boot_log_end'; }
  [ -f "$M/recovery_reason" ] && echo 'auto_rollback=yes'
  echo 'expert_ui_result=not_verified'
}
set_feature() {
  [ "${1:-}" = wcg ] || [ "${1:-}" = expert ] || [ "${1:-}" = hfr ] || { echo 'INVALID_FEATURE'; exit 2; }
  [ "${2:-}" = on ] || [ "${2:-}" = off ] || { echo 'INVALID_VALUE'; exit 2; }
  compat || { echo 'BLOCKED: unsupported firmware'; exit 4; }
  if [ "$1" = hfr ]; then
    if [ "$2" = off ]; then
      rm -f "$M/hfr_enabled"
      echo 'OK: hfr=off (stock Slow Motion unchanged)'
      return 0
    fi
    echo 'BLOCKED: Slow Motion already exists in stock Xiaomi Camera'
    exit 7
  fi
  case "$1" in
    wcg)
      if [ "$2" = on ]; then rm -f "$M/wcg_disabled"; else : > "$M/wcg_disabled"; fi
      ;;
    expert)
      if [ "$2" = on ] && { [ ! -r /data/adb/metamodule/module.prop ] || ! grep -qx 'id=meta-overlayfs' /data/adb/metamodule/module.prop; }; then
        echo 'BLOCKED: compatible meta-overlayfs required for XML overlay'; exit 5
      fi
      if [ "$2" = on ] && [ -f "$M/recovery_reason" ]; then
        echo 'BLOCKED: prior experimental boot failed; inspect recovery first'; exit 6
      fi
      FLAG=expert_enabled
      if [ "$2" = on ]; then : > "$M/$FLAG"; else rm -f "$M/$FLAG"; fi
      # Never mutate overlay files while they may be mounted into /product.
      # post-fs-data.sh regenerates the overlay from the verified baseline
      # before the metamodule mount on the next boot.
      ;;
  esac
  echo "OK: $1=$2 (effective after next reboot)"
}
case "${1:-}" in
  status) status;;
  set) set_feature "${2:-}" "${3:-}";;
  *) echo 'usage: control.sh status | set wcg|expert on|off | set hfr off (legacy)'; exit 2;;
esac
