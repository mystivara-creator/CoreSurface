#!/system/bin/sh
# CoreSurface - Safe Non-Persistent Property Application & Per-Feature Audit
# Pure POSIX sh. Strictly uses `resetprop -n` (memory-only, NEVER writes /data/property,
# and NEVER generates system.prop so KernelSU/Magisk never persists persist.* keys).

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

cs_clear_system_prop() {
  _cs_csp_moddir=$1
  rm -f "$_cs_csp_moddir/system.prop" 2>/dev/null || true
}

cs_resetprop_delete_persist() {
  _cs_dp_key=$1
  [ -n "$_cs_dp_key" ] || return 0
  if [ -z "$CS_RESETPROP_BIN" ]; then
    cs_find_resetprop || return 0
  fi
  if [ "$CS_RESETPROP_MODE" = "magisk" ]; then
    "$CS_RESETPROP_BIN" resetprop -p -d "$_cs_dp_key" 2>/dev/null || true
  else
    "$CS_RESETPROP_BIN" -p -d "$_cs_dp_key" 2>/dev/null || true
  fi
}

# One-time cleanup for devices upgrading from earlier preview builds that had system.prop.
# Purges leaked persist.* keys from /data/property so Toast/Recent Apps regressions vanish immediately.
cs_purge_leaked_persist_props() {
  _cs_marker="$CS_STATE_DIR/.purged_leaked_persist_v1"
  [ -f "$_cs_marker" ] && return 0

  cs_find_resetprop || return 0
  for _cs_leak_k in \
    persist.sys.mi_shadow_supported \
    persist.sys.support_window_mishadow \
    persist.sys.support_view_mishadow \
    persist.sys.support_window_smoothcorner \
    persist.sys.support_view_smoothcorner \
    persist.sys.add_blurnoise_supported \
    persist.sys.multi_task.mask_blur_enable \
    persist.sys.background_blur_setting \
    persist.sys.launcher_blur_supported \
    persist.sys.sf.disable_blurs \
    persist.sys.computility.cpulevel \
    persist.sys.computility.gpulevel \
    persist.sys.computility.version \
    persist.sys.computilityV2.cpulevel \
    persist.sys.computilityV2.gpulevel \
    persist.sys.computilityV2.devicelevel \
    persist.sys.computilityV2.version \
    persist.sys.hyper_transition \
    persist.sys.hyper_transition_v \
    persist.sys.element_transition_supported \
    persist.sys.enable_parallel_sweep \
    persist.hyper.barfollow_anim \
    persist.sys.sf_charge_anim_supported
  do
    cs_resetprop_delete_persist "$_cs_leak_k"
  done

  : > "$_cs_marker" 2>/dev/null || true
  cs_log "Cleanup: purged legacy leaked persist.* keys from /data/property."
  return 0
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

  # Verified flagship animation properties without distorting Recent Apps headers
  # (omits computilityV2.devicelevel=4, shell_anim_enable_fcb, and barfollow_anim).
  case "$CS_RAM_TIER" in
    high)
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "v:1,c:3,g:3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.hyper_transition" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.element_transition_supported" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.enable_parallel_sweep" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.sf_charge_anim_supported" "true"
      ;;
    mid)
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "2"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "v:1,c:2,g:3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.hyper_transition" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.element_transition_supported" "true"
      ;;
    *)
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "2"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "v:1,c:2,g:2"
      ;;
  esac
}

cs_apply_feat_blur() {
  [ "$EFF_FEAT_BLUR" = "1" ] || return 0

  # Clean SurfaceFlinger & HyperOS blur stack (omits backdrop_sampling_enabled,
  # background_blur_setting, MiShadow, smoothcorner, and enable_blurs_on_windows
  # which bloat Toast bounds on HyperOS 3).
  cs_set_prop "FEAT_BLUR" "ro.surface_flinger.supports_background_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.sf.blurs_are_expensive" "0"
  cs_set_prop "FEAT_BLUR" "sf.blurs_are_expensive" "0"
  cs_set_prop "FEAT_BLUR" "ro.miui.has_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.miui.has_real_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.miui.cc_blur_supported" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.miui_folder_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.launcher.blur.appLaunch" "1"
  cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_supported" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_status_default" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_version" "2"

  # HyperOS 3+ drops legacy persist.sys.advanced_visual_release=3; apply only on HyperOS 1/2 & MIUI
  if [ "${CS_HYPEROS_MAJOR:-0}" -lt 3 ]; then
    cs_set_prop "FEAT_BLUR" "persist.sys.advanced_visual_release" "3"
  fi
}

cs_apply_feat_island() {
  [ "$EFF_FEAT_ISLAND" = "1" ] || return 0

  cs_set_prop "FEAT_ISLAND" "persist.sys.feature.island" "1"
  cs_set_prop "FEAT_ISLAND" "persist.sys.feature.island.animation" "true"
  cs_set_prop "FEAT_ISLAND" "persist.sys.feature.island.shader" "true"
}

cs_apply_feat_multitask() {
  [ "$EFF_FEAT_MULTITASK" = "1" ] || return 0

  cs_set_prop "FEAT_MULTITASK" "ro.config.low_ram" "false"
  cs_set_prop "FEAT_MULTITASK" "ro.config.miui_low_ram" "false"
  cs_set_prop "FEAT_MULTITASK" "ro.miui.low_ram" "false"
  cs_set_prop "FEAT_MULTITASK" "ro.config.low_ram.threshold_gb" "0"
  cs_set_prop "FEAT_MULTITASK" "ro.config.low_ram.middle.threshold_gb" "0"
  cs_set_prop "FEAT_MULTITASK" "persist.sys.miui_freeform_max_count" "4"
  cs_set_prop "FEAT_MULTITASK" "ro.miui.support_multi_window" "true"
  cs_set_prop "FEAT_MULTITASK" "ro.support_one_handed_mode" "true"
  cs_set_prop "FEAT_MULTITASK" "ro.miui.has_handy_mode_sf" "1"
  cs_set_prop "FEAT_MULTITASK" "persist.sys.partial.screenshot.support" "true"
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
  _cs_ap_moddir=${1:-}
  cs_watchdog_init_dir || return 1
  : > "$CS_PROPS_AUDIT_FILE"

  # Ensure no system.prop ever exists (strictly non-persistent resetprop -n only)
  if [ -n "$_cs_ap_moddir" ]; then
    cs_clear_system_prop "$_cs_ap_moddir"
  fi

  if ! cs_find_resetprop; then
    cs_log "ERROR: resetprop not available; skipping all property writes."
    return 1
  fi

  # Purge any leaked persist.* properties from earlier preview builds
  cs_purge_leaked_persist_props || true

  cs_apply_feat_animations
  cs_apply_feat_blur
  cs_apply_feat_island
  cs_apply_feat_multitask
  cs_apply_feat_display_hz
  cs_apply_feat_hyperai
  cs_apply_feat_aod_unlock

  _cs_count=$(wc -l < "$CS_PROPS_AUDIT_FILE" 2>/dev/null | tr -d ' \t\r\n')
  cs_state_set "APPLIED_PROPS_COUNT" "${_cs_count:-0}"
  cs_log "Applied ${_cs_count:-0} non-persistent props (blur=${EFF_FEAT_BLUR}, anim=${EFF_FEAT_ANIMATIONS}, island=${EFF_FEAT_ISLAND}, multitask=${EFF_FEAT_MULTITASK}, hz=${EFF_FEAT_DISPLAY_HZ}, ai=${EFF_FEAT_HYPERAI}, aod=${EFF_FEAT_AOD_UNLOCK})."
  return 0
}
