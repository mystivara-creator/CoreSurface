#!/system/bin/sh
# CoreSurface - Layer 4: Safe Non-Persistent Property Application & Audit
# Pure POSIX sh. Strictly uses `resetprop -n` (memory-only, no /data/property writes).

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

# Strictly apply a property with -n (no-persist) and record it in audit list.
# Never falls back to resetprop without -n so persist.* props never stick in /data/property.
cs_set_prop() {
  _cs_sp_tier=$1
  _cs_sp_key=$2
  _cs_sp_val=$3

  if [ -z "$_cs_sp_key" ] || [ -z "$_cs_sp_val" ]; then
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

  printf '%s|%s=%s\n' "$_cs_sp_tier" "$_cs_sp_key" "$_cs_sp_val" >> "$CS_PROPS_AUDIT_FILE"
  return 0
}

cs_apply_tier1() {
  [ "$EFF_TIER1" = "1" ] || return 0

  case "$CS_RAM_TIER" in
    high)
      cs_set_prop "tier1" "ro.miui.device_level" "3"
      cs_set_prop "tier1" "persist.sys.deviceLevelList" "v:1,c:3,g:3"
      ;;
    mid)
      cs_set_prop "tier1" "ro.miui.device_level" "2"
      cs_set_prop "tier1" "persist.sys.deviceLevelList" "v:1,c:2,g:3"
      ;;
    *)
      cs_set_prop "tier1" "ro.miui.device_level" "2"
      cs_set_prop "tier1" "persist.sys.deviceLevelList" "v:1,c:2,g:2"
      ;;
  esac

  # Control Center & Folder blur (lightweight UI polish)
  cs_set_prop "tier1" "ro.miui.cc_blur_supported" "true"
  cs_set_prop "tier1" "persist.sys.miui_folder_blur" "1"

  # Heavy Advanced Textures / Background Blur only when RAM >= 6 GB
  if [ "$EFF_TIER1_HEAVY_BLUR" = "1" ]; then
    cs_set_prop "tier1" "persist.sys.background_blur_supported" "true"
    cs_set_prop "tier1" "persist.sys.background_blur_status_default" "true"
    cs_set_prop "tier1" "persist.sys.background_blur_version" "2"
    cs_set_prop "tier1" "persist.sys.advanced_visual_release" "3"
    cs_set_prop "tier1" "ro.surface_flinger.supports_background_blur" "1"
  fi
}

cs_apply_tier2() {
  [ "$EFF_TIER2" = "1" ] || return 0

  # Low-RAM threshold relaxation
  cs_set_prop "tier2" "ro.config.low_ram" "false"
  cs_set_prop "tier2" "ro.config.miui_low_ram" "false"
  cs_set_prop "tier2" "ro.miui.low_ram" "false"

  # Floating window / multi-window relaxation
  cs_set_prop "tier2" "persist.sys.miui_freeform_max_count" "4"
  cs_set_prop "tier2" "ro.miui.support_multi_window" "true"

  # High refresh rate support
  cs_set_prop "tier2" "ro.miui.support_high_refresh_rate" "true"
  cs_set_prop "tier2" "ro.vendor.fps.switch.default" "true"
}

cs_apply_tier3() {
  [ "$EFF_TIER3" = "1" ] || return 0

  # HyperAI / AI Gallery (version-gated: HyperOS + SDK >= 34)
  if [ "$EFF_TIER3_HYPERAI" = "1" ]; then
    cs_set_prop "tier3" "persist.sys.miui_ai_supported" "true"
    cs_set_prop "tier3" "persist.sys.hyperai_enabled" "true"
    cs_set_prop "tier3" "ro.miui.gallery_ai_enable" "true"
  fi

  # AOD 10s limit unlock
  if [ "$EFF_TIER3_AOD_UNLOCK" = "1" ]; then
    cs_set_prop "tier3" "ro.miui.aod_always_on_supported" "true"
    cs_set_prop "tier3" "persist.sys.aod_limit_disabled" "true"
  fi
}

cs_apply_all_tiers() {
  cs_watchdog_init_dir || return 1
  : > "$CS_PROPS_AUDIT_FILE"

  if ! cs_find_resetprop; then
    cs_log "ERROR: resetprop not available; skipping all property writes."
    return 1
  fi

  cs_apply_tier1
  cs_apply_tier2
  cs_apply_tier3

  _cs_count=$(wc -l < "$CS_PROPS_AUDIT_FILE" 2>/dev/null | tr -d ' \t\r\n')
  cs_state_set "APPLIED_PROPS_COUNT" "${_cs_count:-0}"
  cs_log "Applied ${_cs_count:-0} user-space properties (tier1=${EFF_TIER1}, heavy_blur=${EFF_TIER1_HEAVY_BLUR}, tier2=${EFF_TIER2}, tier3=${EFF_TIER3})."
  return 0
}
