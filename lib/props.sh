#!/system/bin/sh
# CoreSurface - Safe Non-Persistent Property Application, system.prop Generator & Audit
# Pure POSIX sh. Strictly uses `resetprop -n` (memory-only, never writes /data/property).
# Also generates $MODDIR/system.prop so KernelSU-Next applies props AFTER load_persist_props
# and BEFORE Zygote/SystemUI/Launcher boot, and clears system.prop fail-closed on Safe-Mode.

CS_RESETPROP_MODE=""
CS_RESETPROP_BIN=""
CS_PROPS_WRITE_ONLY="0"
CS_SYSPROP_TMP=""

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

# Strictly apply a property with -n (no-persist), write to system.prop buffer, and record audit.
cs_set_prop() {
  _cs_sp_feat=$1
  _cs_sp_key=$2
  _cs_sp_val=$3

  if [ -z "$_cs_sp_feat" ] || [ -z "$_cs_sp_key" ] || [ -z "$_cs_sp_val" ]; then
    return 1
  fi

  if [ -n "$CS_SYSPROP_TMP" ]; then
    printf '%s=%s\n' "$_cs_sp_key" "$_cs_sp_val" >> "$CS_SYSPROP_TMP"
  fi

  if [ "$CS_PROPS_WRITE_ONLY" = "1" ]; then
    return 0
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
      # HyperOS 2/3 flagship animation engine (Computility V2 + HyperTransition)
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.cpulevel" "4"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.gpulevel" "4"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.devicelevel" "4"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.version" "2026"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.hyper_transition" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.hyper_transition_v" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.element_transition_supported" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.enable_parallel_sweep" "true"
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.shell_anim_enable_fcb" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.hyper.barfollow_anim" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.sf_charge_anim_supported" "true"
      ;;
    mid)
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "2"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "v:1,c:2,g:3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.cpulevel" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.gpulevel" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.devicelevel" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.version" "2026"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.hyper_transition" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.element_transition_supported" "true"
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.shell_anim_enable_fcb" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.hyper.barfollow_anim" "true"
      ;;
    *)
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "2"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "v:1,c:2,g:2"
      cs_set_prop "FEAT_ANIMATIONS" "ro.miui.shell_anim_enable_fcb" "true"
      ;;
  esac
}

cs_apply_feat_blur() {
  [ "$EFF_FEAT_BLUR" = "1" ] || return 0

  # Consistent SurfaceFlinger & HyperOS UI blur without bloating Toast bounds
  # or breaking Recent Apps layout on HyperOS 3.
  cs_set_prop "FEAT_BLUR" "ro.surface_flinger.supports_background_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.sf.blurs_are_expensive" "0"
  cs_set_prop "FEAT_BLUR" "sf.blurs_are_expensive" "0"
  cs_set_prop "FEAT_BLUR" "persist.sys.sf.disable_blurs" "false"
  cs_set_prop "FEAT_BLUR" "ro.miui.has_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.miui.has_real_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.miui.backdrop_sampling_enabled" "true"
  cs_set_prop "FEAT_BLUR" "ro.miui.cc_blur_supported" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.miui_folder_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.launcher.blur.appLaunch" "1"
  cs_set_prop "FEAT_BLUR" "persist.sys.launcher_blur_supported" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_supported" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_status_default" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_setting" "1"
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

  # Low-RAM boolean & GB threshold relaxation (also enables full Control Center swipe animations)
  # Intentionally omits ro.multiwin.fulldecor_support which distorts Recent Apps layout on HyperOS 3.
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

cs_emit_all_props() {
  cs_apply_feat_animations
  cs_apply_feat_blur
  cs_apply_feat_island
  cs_apply_feat_multitask
  cs_apply_feat_display_hz
  cs_apply_feat_hyperai
  cs_apply_feat_aod_unlock
}

# Generate $MODDIR/system.prop for next boot without calling resetprop (used in customize.sh & webui_ctl.sh).
cs_generate_system_prop() {
  _cs_gsp_moddir=$1
  CS_SYSPROP_TMP="$_cs_gsp_moddir/system.prop.tmp.$$"
  CS_PROPS_WRITE_ONLY="1"
  : > "$CS_SYSPROP_TMP"

  cs_emit_all_props

  CS_PROPS_WRITE_ONLY="0"
  if [ -s "$CS_SYSPROP_TMP" ]; then
    chmod 0644 "$CS_SYSPROP_TMP" 2>/dev/null || true
    mv -f "$CS_SYSPROP_TMP" "$_cs_gsp_moddir/system.prop"
  else
    rm -f "$CS_SYSPROP_TMP" "$_cs_gsp_moddir/system.prop" 2>/dev/null || true
  fi
  CS_SYSPROP_TMP=""
}

cs_apply_all_props() {
  _cs_ap_moddir=${1:-}
  cs_watchdog_init_dir || return 1
  : > "$CS_PROPS_AUDIT_FILE"

  if ! cs_find_resetprop; then
    cs_log "ERROR: resetprop not available; skipping all property writes."
    return 1
  fi

  CS_PROPS_WRITE_ONLY="0"
  if [ -n "$_cs_ap_moddir" ]; then
    CS_SYSPROP_TMP="$_cs_ap_moddir/system.prop.tmp.$$"
    : > "$CS_SYSPROP_TMP"
  else
    CS_SYSPROP_TMP=""
  fi

  cs_emit_all_props

  if [ -n "$CS_SYSPROP_TMP" ]; then
    if [ -s "$CS_SYSPROP_TMP" ]; then
      chmod 0644 "$CS_SYSPROP_TMP" 2>/dev/null || true
      mv -f "$CS_SYSPROP_TMP" "$_cs_ap_moddir/system.prop"
    else
      rm -f "$CS_SYSPROP_TMP" "$_cs_ap_moddir/system.prop" 2>/dev/null || true
    fi
    CS_SYSPROP_TMP=""
  fi

  _cs_count=$(wc -l < "$CS_PROPS_AUDIT_FILE" 2>/dev/null | tr -d ' \t\r\n')
  cs_state_set "APPLIED_PROPS_COUNT" "${_cs_count:-0}"
  cs_log "Applied ${_cs_count:-0} non-persistent props (blur=${EFF_FEAT_BLUR}, anim=${EFF_FEAT_ANIMATIONS}, island=${EFF_FEAT_ISLAND}, multitask=${EFF_FEAT_MULTITASK}, hz=${EFF_FEAT_DISPLAY_HZ}, ai=${EFF_FEAT_HYPERAI}, aod=${EFF_FEAT_AOD_UNLOCK})."
  return 0
}
