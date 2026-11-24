#!/system/bin/sh
# CoreSurface - Safe Non-Persistent Property Application & Per-Feature Audit
# Pure POSIX sh. Strictly uses `resetprop -n` (memory-only, never writes /data/property).

CS_RESETPROP_MODE=""
CS_RESETPROP_BIN=""

cs_find_resetprop() {
  CS_RESETPROP_MODE=""
  CS_RESETPROP_BIN=""

  if command -v resetprop >/dev/null 2>&1; then
    CS_RESETPROP_MODE="direct"
    CS_RESETPROP_BIN=$(command -v resetprop)
    return 0
  fi

  if [ -x /data/adb/ksu/bin/resetprop ]; then
    CS_RESETPROP_MODE="direct"
    CS_RESETPROP_BIN="/data/adb/ksu/bin/resetprop"
    return 0
  fi

  if [ -x /data/adb/magisk/magisk ]; then
    CS_RESETPROP_MODE="magisk"
    CS_RESETPROP_BIN="/data/adb/magisk/magisk"
    return 0
  fi

  return 1
}

# Strictly apply a property with -n (no-persist) and record feature|key=value in audit list.
# Never falls back to resetprop without -n so persist.* props never stick in /data/property.
cs_set_prop() {
  _cs_sp_feat=$1
  _cs_sp_key=$2
  _cs_sp_val=$3

  if [ -z "$_cs_sp_feat" ] || [ -z "$_cs_sp_key" ] || [ -z "$_cs_sp_val" ]; then
    return 1
  fi

  if [ -z "$CS_RESETPROP_BIN" ]; then
    cs_find_resetprop || {
      cs_log "ERROR: resetprop binary not found; cannot apply ${_cs_sp_key}"
      return 1
    }
  fi

  if [ "$CS_RESETPROP_MODE" = "magisk" ]; then
    "$CS_RESETPROP_BIN" resetprop -n "$_cs_sp_key" "$_cs_sp_val" 2>/dev/null || {
      cs_log "WARN: failed resetprop -n ${_cs_sp_key}=${_cs_sp_val}"
      return 1
    }
  else
    "$CS_RESETPROP_BIN" -n "$_cs_sp_key" "$_cs_sp_val" 2>/dev/null || {
      cs_log "WARN: failed resetprop -n ${_cs_sp_key}=${_cs_sp_val}"
      return 1
    }
  fi

  printf '%s|%s=%s\n' "$_cs_sp_feat" "$_cs_sp_key" "$_cs_sp_val" >> "$CS_PROPS_AUDIT_FILE"
  return 0
}

cs_apply_feat_animations() {
  [ "$EFF_FEAT_ANIMATIONS" = "1" ] || return 0

  case "$CS_RAM_TIER" in
    high)
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "v:1,c:3,g:3"
      ;;
    mid)
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "2"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "v:1,c:2,g:3"
      ;;
    *)
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "2"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "v:1,c:2,g:2"
      ;;
  esac
}

cs_apply_feat_blur() {
  [ "$EFF_FEAT_BLUR" = "1" ] || return 0

  cs_set_prop "FEAT_BLUR" "ro.miui.cc_blur_supported" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.miui_folder_blur" "1"
  cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_supported" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_status_default" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_version" "2"
  cs_set_prop "FEAT_BLUR" "persist.sys.advanced_visual_release" "3"
  cs_set_prop "FEAT_BLUR" "ro.surface_flinger.supports_background_blur" "1"
}

cs_apply_feat_multitask() {
  [ "$EFF_FEAT_MULTITASK" = "1" ] || return 0

  cs_set_prop "FEAT_MULTITASK" "ro.config.low_ram" "false"
  cs_set_prop "FEAT_MULTITASK" "ro.config.miui_low_ram" "false"
  cs_set_prop "FEAT_MULTITASK" "ro.miui.low_ram" "false"
  cs_set_prop "FEAT_MULTITASK" "persist.sys.miui_freeform_max_count" "4"
  cs_set_prop "FEAT_MULTITASK" "ro.miui.support_multi_window" "true"
}

cs_apply_feat_display_hz() {
  [ "$EFF_FEAT_DISPLAY_HZ" = "1" ] || return 0

  cs_set_prop "FEAT_DISPLAY_HZ" "ro.miui.support_high_refresh_rate" "true"
  cs_set_prop "FEAT_DISPLAY_HZ" "ro.vendor.fps.switch.default" "true"
}

cs_apply_feat_hyperai() {
  [ "$EFF_FEAT_HYPERAI" = "1" ] || return 0

  cs_set_prop "FEAT_HYPERAI" "persist.sys.miui_ai_supported" "true"
  cs_set_prop "FEAT_HYPERAI" "persist.sys.hyperai_enabled" "true"
  cs_set_prop "FEAT_HYPERAI" "ro.miui.gallery_ai_enable" "true"
}

cs_apply_feat_aod_unlock() {
  [ "$EFF_FEAT_AOD_UNLOCK" = "1" ] || return 0

  cs_set_prop "FEAT_AOD_UNLOCK" "ro.miui.aod_always_on_supported" "true"
  cs_set_prop "FEAT_AOD_UNLOCK" "persist.sys.aod_limit_disabled" "true"
}

cs_apply_all_props() {
  cs_watchdog_init_dir || return 1
  : > "$CS_PROPS_AUDIT_FILE"

  if ! cs_find_resetprop; then
    cs_log "ERROR: resetprop not available; skipping all property writes."
    return 1
  fi

  cs_apply_feat_animations
  cs_apply_feat_blur
  cs_apply_feat_multitask
  cs_apply_feat_display_hz
  cs_apply_feat_hyperai
  cs_apply_feat_aod_unlock

  _cs_count=$(wc -l < "$CS_PROPS_AUDIT_FILE" 2>/dev/null | tr -d ' \t\r\n')
  cs_state_set "APPLIED_PROPS_COUNT" "${_cs_count:-0}"
  cs_log "Applied ${_cs_count:-0} non-persistent props (blur=${EFF_FEAT_BLUR}, anim=${EFF_FEAT_ANIMATIONS}, multitask=${EFF_FEAT_MULTITASK}, hz=${EFF_FEAT_DISPLAY_HZ}, ai=${EFF_FEAT_HYPERAI}, aod=${EFF_FEAT_AOD_UNLOCK})."
  return 0
}
