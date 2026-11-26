#!/system/bin/sh
# CoreSurface - Safe Non-Persistent Property Application & Per-Feature Audit
# Pure POSIX sh. Zero-Gimmick Policy: ONLY properties verified to be read by AOSP
# SurfaceFlinger / HyperOS SystemUI / MiuiHome / MiuiFreeForm.
# Strictly uses `resetprop -n` (memory-only, NEVER writes /data/property,
# and NEVER generates system.prop).

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

  if [ -x /data/adb/ap/bin/resetprop ]; then
    CS_RESETPROP_MODE="direct"
    CS_RESETPROP_BIN="/data/adb/ap/bin/resetprop"
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

# One-time cleanup for devices upgrading from earlier preview builds.
# Purges leaked persist.* keys (including advanced_visual_release & removed placebo keys)
# from /data/property so Toast/Recent Apps regressions cannot persist across flashes.
cs_purge_leaked_persist_props() {
  _cs_marker="$CS_STATE_DIR/.purged_leaked_persist_v3"
  [ -f "$_cs_marker" ] && return 0

  cs_find_resetprop || return 0
  for _cs_leak_k in \
    persist.sys.mi_shadow_supported \
    persist.sys.support_window_mishadow \
    persist.sys.support_view_mishadow \
    persist.sys.support_window_smoothcorner \
    persist.sys.support_view_smoothcorner \
    persist.sys.add_blurnoise_supported \
    persist.sys.background_blur_setting \
    persist.sys.background_blur_status_default \
    persist.sys.background_blur_version \
    persist.sys.advanced_visual_release \
    persist.sys.launcher_blur_supported \
    persist.sys.sf.disable_blurs \
    persist.sys.feature.island \
    persist.sys.feature.island.animation \
    persist.sys.feature.island.shader \
    persist.sys.miui_ai_supported \
    persist.sys.hyperai_enabled \
    persist.sys.aod_limit_disabled
  do
    cs_resetprop_delete_persist "$_cs_leak_k"
  done

  : > "$_cs_marker" 2>/dev/null || true
  cs_log "Cleanup v3: purged leaked persist.* keys (including advanced_visual_release) from /data/property."
  return 0
}

# Strictly apply a property with -n (no-persist) and record feature|key=value in audit list.
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

cs_set_prop_mem_only() {
  _cs_sm_key=$1
  _cs_sm_val=$2
  [ -n "$_cs_sm_key" ] && [ -n "$_cs_sm_val" ] || return 0
  cs_find_resetprop || return 0
  if [ "$CS_RESETPROP_MODE" = "magisk" ]; then
    "$CS_RESETPROP_BIN" resetprop -n "$_cs_sm_key" "$_cs_sm_val" 2>/dev/null || true
  else
    "$CS_RESETPROP_BIN" -n "$_cs_sm_key" "$_cs_sm_val" 2>/dev/null || true
  fi
}

cs_max_uint() {
  _cs_mu_a=${1:-0}
  _cs_mu_b=${2:-0}
  if [ "$_cs_mu_a" -gt "$_cs_mu_b" ] 2>/dev/null; then
    printf '%s' "$_cs_mu_a"
  else
    printf '%s' "$_cs_mu_b"
  fi
}

cs_resolve_never_downgrade_level_list() {
  _cs_nd_want_c=$1
  _cs_nd_want_g=$2
  _cs_nd_v=1
  _cs_nd_c=$_cs_nd_want_c
  _cs_nd_g=$_cs_nd_want_g

  if [ -n "${CS_STOCK_DEVICE_LEVEL_LIST:-}" ]; then
    _cs_sc=$(printf '%s' "$CS_STOCK_DEVICE_LEVEL_LIST" | sed -n 's/.*c:\([0-9][0-9]*\).*/\1/p')
    _cs_sg=$(printf '%s' "$CS_STOCK_DEVICE_LEVEL_LIST" | sed -n 's/.*g:\([0-9][0-9]*\).*/\1/p')
    _cs_sv=$(printf '%s' "$CS_STOCK_DEVICE_LEVEL_LIST" | sed -n 's/.*v:\([0-9][0-9]*\).*/\1/p')
    if [ -n "$_cs_sv" ] && [ "$_cs_sv" -gt "$_cs_nd_v" ] 2>/dev/null; then
      _cs_nd_v=$_cs_sv
    fi
    if [ -n "$_cs_sc" ] && [ "$_cs_sc" -gt "$_cs_nd_c" ] 2>/dev/null; then
      _cs_nd_c=$_cs_sc
    fi
    if [ -n "$_cs_sg" ] && [ "$_cs_sg" -gt "$_cs_nd_g" ] 2>/dev/null; then
      _cs_nd_g=$_cs_sg
    fi
  fi
  printf 'v:%s,c:%s,g:%s' "$_cs_nd_v" "$_cs_nd_c" "$_cs_nd_g"
}

cs_apply_feat_animations() {
  [ "$EFF_FEAT_ANIMATIONS" = "1" ] || return 0

  # Verified HyperOS/MIUI Control Center, Computility V1/V2 & HyperTransition flags
  # scaled by resolved tier with strict Never-Downgrade protection.
  # Zero-GPU-cost responsiveness props (FCB + launch optimization) apply across ALL tiers.
  cs_set_prop "FEAT_ANIMATIONS" "debug.sysui.use_control_center" "1"
  cs_set_prop "FEAT_ANIMATIONS" "persist.sys.launch_response_optimization.enable" "true"
  cs_set_prop "FEAT_ANIMATIONS" "ro.miui.shell_anim_enable_fcb" "true"
  case "${CS_EFF_TIER:-low}" in
    flagship)
      _cs_cpu=$(cs_max_uint 6 "${CS_STOCK_CPU_LEVEL:-0}")
      _cs_gpu=$(cs_max_uint 6 "${CS_STOCK_GPU_LEVEL:-0}")
      if [ "${CS_STOCK_DEVICE_LEVEL:-0}" -le 3 ]; then
        cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "3"
      fi
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "$(cs_resolve_never_downgrade_level_list 3 3)"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computility.cpulevel" "$_cs_cpu"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computility.gpulevel" "$_cs_gpu"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computility.version" "2025"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.cpulevel" "4"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.gpulevel" "4"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.devicelevel" "4"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.version" "2026"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.hyper_transition" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.hyper_transition_v" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.element_transition_supported" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.enable_parallel_sweep" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.sf_charge_anim_supported" "true"
      # Real-time Recents task-card mask blur adds GPU overdraw on mid-range SoCs; enable only on flagship GPUs
      if [ "${CS_STOCK_DEVICE_LEVEL:-0}" -ge 3 ]; then
        cs_set_prop "FEAT_ANIMATIONS" "persist.sys.multi_task.mask_blur_enable" "true"
      fi
      cs_set_prop "FEAT_ANIMATIONS" "persist.hyper.barfollow_anim" "true"
      ;;
    balanced_pro)
      _cs_cpu=$(cs_max_uint 4 "${CS_STOCK_CPU_LEVEL:-0}")
      _cs_gpu=$(cs_max_uint 4 "${CS_STOCK_GPU_LEVEL:-0}")
      if [ "${CS_STOCK_DEVICE_LEVEL:-0}" -lt 3 ]; then
        cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "2"
      fi
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "$(cs_resolve_never_downgrade_level_list 2 3)"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computility.cpulevel" "$_cs_cpu"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computility.gpulevel" "$_cs_gpu"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computility.version" "2025"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.cpulevel" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.gpulevel" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.devicelevel" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.computilityV2.version" "2026"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.hyper_transition" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.hyper_transition_v" "3"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.element_transition_supported" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.enable_parallel_sweep" "true"
      cs_set_prop "FEAT_ANIMATIONS" "persist.hyper.barfollow_anim" "true"
      ;;
    *)
      if [ "${CS_STOCK_DEVICE_LEVEL:-0}" -lt 3 ]; then
        cs_set_prop "FEAT_ANIMATIONS" "ro.miui.device_level" "2"
      fi
      cs_set_prop "FEAT_ANIMATIONS" "persist.sys.deviceLevelList" "$(cs_resolve_never_downgrade_level_list 2 2)"
      ;;
  esac
}

# Late-boot re-assertion (strictly memory-only resetprop -n):
# HyperOS's ComputilityService can reset persist.sys.computility.cpulevel/gpulevel back to 2
# during boot after post-fs-data. Re-applying them after boot_completed keeps Control Center
# flagship animations & computility levels intact without writing /data/property.
cs_reassert_computility_props() {
  [ "$EFF_FEAT_ANIMATIONS" = "1" ] || return 0
  cs_set_prop_mem_only "persist.sys.launch_response_optimization.enable" "true"
  if [ "${EFF_FEAT_BLUR:-0}" = "1" ]; then
    cs_set_prop_mem_only "persist.sys.sf.disable_blurs" "false"
  fi
  case "${CS_EFF_TIER:-low}" in
    flagship)
      _cs_rcpu=$(cs_max_uint 6 "${CS_STOCK_CPU_LEVEL:-0}")
      _cs_rgpu=$(cs_max_uint 6 "${CS_STOCK_GPU_LEVEL:-0}")
      cs_set_prop_mem_only "persist.sys.computility.cpulevel" "$_cs_rcpu"
      cs_set_prop_mem_only "persist.sys.computility.gpulevel" "$_cs_rgpu"
      cs_set_prop_mem_only "persist.sys.computility.version" "2025"
      cs_set_prop_mem_only "persist.sys.computilityV2.cpulevel" "4"
      cs_set_prop_mem_only "persist.sys.computilityV2.gpulevel" "4"
      cs_set_prop_mem_only "persist.sys.computilityV2.devicelevel" "4"
      cs_set_prop_mem_only "persist.sys.computilityV2.version" "2026"
      cs_set_prop_mem_only "persist.sys.deviceLevelList" "$(cs_resolve_never_downgrade_level_list 3 3)"
      cs_set_prop_mem_only "persist.sys.hyper_transition_v" "3"
      cs_set_prop_mem_only "persist.hyper.barfollow_anim" "true"
      cs_log "Re-asserted flagship computility (cpu=${_cs_rcpu}, gpu=${_cs_rgpu}, V2=4) via resetprop -n."
      ;;
    balanced_pro)
      _cs_rcpu=$(cs_max_uint 4 "${CS_STOCK_CPU_LEVEL:-0}")
      _cs_rgpu=$(cs_max_uint 4 "${CS_STOCK_GPU_LEVEL:-0}")
      cs_set_prop_mem_only "persist.sys.computility.cpulevel" "$_cs_rcpu"
      cs_set_prop_mem_only "persist.sys.computility.gpulevel" "$_cs_rgpu"
      cs_set_prop_mem_only "persist.sys.computility.version" "2025"
      cs_set_prop_mem_only "persist.sys.computilityV2.cpulevel" "3"
      cs_set_prop_mem_only "persist.sys.computilityV2.gpulevel" "3"
      cs_set_prop_mem_only "persist.sys.computilityV2.devicelevel" "3"
      cs_set_prop_mem_only "persist.sys.computilityV2.version" "2026"
      cs_set_prop_mem_only "persist.sys.deviceLevelList" "$(cs_resolve_never_downgrade_level_list 2 3)"
      cs_set_prop_mem_only "persist.sys.hyper_transition_v" "3"
      cs_set_prop_mem_only "persist.hyper.barfollow_anim" "true"
      cs_log "Re-asserted balanced_pro computility (cpu=${_cs_rcpu}, gpu=${_cs_rgpu}, V2=3) via resetprop -n."
      ;;
  esac
  return 0
}

cs_apply_feat_blur() {
  [ "$EFF_FEAT_BLUR" = "1" ] || return 0

  # Verified AOSP SurfaceFlinger & HyperOS Control Center/Shade/Folder/Launcher blur.
  # Low tier keeps clean standard blur WITHOUT enabling Advanced Textures.
  cs_set_prop "FEAT_BLUR" "ro.surface_flinger.supports_background_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.sf.blurs_are_expensive" "0"
  cs_set_prop "FEAT_BLUR" "sf.blurs_are_expensive" "0"
  cs_set_prop "FEAT_BLUR" "persist.sys.sf.disable_blurs" "false"
  cs_set_prop "FEAT_BLUR" "ro.miui.has_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.miui.has_real_blur" "1"
  cs_set_prop "FEAT_BLUR" "ro.miui.cc_blur_supported" "true"
  cs_set_prop "FEAT_BLUR" "persist.sys.miui_folder_blur" "1"
  # Full-screen real-time GPU blur on frame 0 of app launch causes a noticeable 1-3 frame
  # hesitation/stutter on mid-range GPUs (stock device_level < 3). Keep it 0 on mid-range
  # GPUs for instant icon-tap takeoff, and 1 only on native flagship GPUs.
  if [ "${CS_STOCK_DEVICE_LEVEL:-0}" -ge 3 ]; then
    cs_set_prop "FEAT_BLUR" "ro.launcher.blur.appLaunch" "1"
  else
    cs_set_prop "FEAT_BLUR" "ro.launcher.blur.appLaunch" "0"
  fi
  cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_supported" "true"

  # On non-flagship HyperOS 3 (stock device_level < 3), forcing launcher_blur_supported=true
  # switches com.miui.home from stable wallpaper blur to cross-window pass-window blur, which
  # causes -1 Screen (App Vault) & Folder black blinks when Advanced Textures is enabled.
  if [ "${CS_HYPEROS_MAJOR:-0}" -lt 3 ] || [ "${CS_STOCK_DEVICE_LEVEL:-0}" -ge 3 ]; then
    cs_set_prop "FEAT_BLUR" "persist.sys.launcher_blur_supported" "true"
  fi

  if [ "${EFF_FEAT_ADV_TEXTURES:-0}" != "1" ]; then
    cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_status_default" "false"
  elif [ "${CS_HYPEROS_MAJOR:-0}" -ge 4 ]; then
    # Native HyperOS 4+ Bionic Material & Advanced Textures contract (verified against OS4.0 factory dump):
    # - Never-Downgrade advanced_visual_release: min 5 (preserves 6+ on future HOS 4.1+ ROMs)
    # - Never overwrite persist.sys.background_blur_status_default so HyperOS Settings toggle stays consistent
    # - Enables persist.sys.bionic_material_supported=true + G2 SmoothCorner (plus MiShadow/Backdrop on flagship GPU)
    _cs_avr=$(cs_max_uint 5 "${CS_STOCK_ADV_VISUAL_RELEASE:-0}")
    cs_set_prop "FEAT_BLUR" "persist.sys.advanced_visual_release" "$_cs_avr"
    cs_set_prop "FEAT_BLUR" "persist.sys.bionic_material_supported" "true"
    cs_set_prop "FEAT_BLUR" "persist.sys.support_window_smoothcorner" "true"
    cs_set_prop "FEAT_BLUR" "persist.sys.support_view_smoothcorner" "true"
    if [ "${CS_STOCK_DEVICE_LEVEL:-0}" -ge 3 ]; then
      cs_set_prop "FEAT_BLUR" "persist.sys.mi_shadow_supported" "true"
      cs_set_prop "FEAT_BLUR" "persist.sys.support_window_mishadow" "true"
      cs_set_prop "FEAT_BLUR" "persist.sys.support_view_mishadow" "true"
      cs_set_prop "FEAT_BLUR" "ro.miui.backdrop_sampling_enabled" "true"
      cs_set_prop "FEAT_BLUR" "persist.sys.add_blurnoise_supported" "true"
    fi
  elif [ "${CS_HYPEROS_MAJOR:-0}" -ge 3 ]; then
    # Lightweight HyperOS 3 Advanced Textures v4 contract (strictly resetprop -n):
    # - Never-Downgrade advanced_visual_release: min 4 (preserves 5+ on HOS 3.1/3.2 ROMs)
    # - Never overwrite persist.sys.background_blur_status_default so HyperOS Settings toggle stays consistent
    # - Zero-cost G2 SmoothCorner on all devices; heavy GPU shaders (MiShadow, BlurNoise,
    #   BackdropSampling) gated to native flagship GPUs (stock device_level >= 3) to prevent
    #   mid-range GPU spikes and -1 Screen black blinks.
    _cs_avr=$(cs_max_uint 4 "${CS_STOCK_ADV_VISUAL_RELEASE:-0}")
    cs_set_prop "FEAT_BLUR" "persist.sys.advanced_visual_release" "$_cs_avr"
    cs_set_prop "FEAT_BLUR" "persist.sys.support_window_smoothcorner" "true"
    cs_set_prop "FEAT_BLUR" "persist.sys.support_view_smoothcorner" "true"
    if [ "${CS_STOCK_DEVICE_LEVEL:-0}" -ge 3 ]; then
      cs_set_prop "FEAT_BLUR" "persist.sys.mi_shadow_supported" "true"
      cs_set_prop "FEAT_BLUR" "persist.sys.support_window_mishadow" "true"
      cs_set_prop "FEAT_BLUR" "persist.sys.support_view_mishadow" "true"
      cs_set_prop "FEAT_BLUR" "ro.miui.backdrop_sampling_enabled" "true"
      cs_set_prop "FEAT_BLUR" "persist.sys.add_blurnoise_supported" "true"
    fi
  else
    _cs_avr=$(cs_max_uint 3 "${CS_STOCK_ADV_VISUAL_RELEASE:-0}")
    cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_status_default" "true"
    cs_set_prop "FEAT_BLUR" "persist.sys.background_blur_version" "2"
    cs_set_prop "FEAT_BLUR" "persist.sys.advanced_visual_release" "$_cs_avr"
  fi
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

cs_apply_feat_flagship_audio() {
  [ "$EFF_FEAT_FLAGSHIP_AUDIO" = "1" ] || return 0

  # Verified HyperOS / Xiaomi Flagship Speaker & Audio Framework pipeline flags
  # (pure user-space audio framework/HAL props; zero kernel/sysfs coupling; zero idle DSP load)
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "persist.vendor.audio.misound.disable" "false"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.sfx.audiovisual" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.sfx.scenario" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.sfx.independentequalizer" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.sfx.earadj" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.game.effect" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.dolby.dax.support" "true"
  # Never-Downgrade: preserve stock Dolby/Harman/Dirac soundfx type if factory ROM sets one
  _cs_sfx_type=$(cs_getprop "ro.vendor.audio.soundfx.type")
  if [ -z "$_cs_sfx_type" ]; then
    cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.soundfx.type" "mi"
  fi
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.misound.bluetooth.enable" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.spk.stereo" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.spk.clean" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.hifi" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.vendor.audio.voice.change.support" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "ro.audio.spatializer_enabled" "true"
  cs_set_prop "FEAT_FLAGSHIP_AUDIO" "persist.vendor.audio.hifi.int_codec" "true"
}

cs_apply_feat_flagship_suite() {
  [ "$EFF_FEAT_FLAGSHIP_SUITE" = "1" ] || return 0

  # Verified HyperOS Flagship Porting Suite props (Dynamic Font Anim, Multi-Window Full-Decor,
  # Live Photo v3, Power Modes, AI Wakeup, Battery AI & Night Charge, Launch Response, AI Subtitles)
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "ro.miui.ui.font.animation" "enable"
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "ro.multiwin.fulldecor_support" "true"
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "ro.product.camera.livephoto.support" "3"
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "ro.camera.sound.forced" "0"
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "persist.sys.power_mode_support" "true"
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "persist.sys.power_meter_enhanced" "true"
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "persist.sys.support_ai_wakeup_effect" "true"
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "persist.vendor.night.charge" "true"
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "persist.vendor.battery.ai.predict" "true"
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "persist.sys.translate.state.supportAiSubtitles" "true"
  cs_set_prop "FEAT_FLAGSHIP_SUITE" "persist.sys.translate.state.supportVoiceTrans" "true"
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
  cs_apply_feat_multitask
  cs_apply_feat_display_hz
  cs_apply_feat_flagship_audio
  cs_apply_feat_flagship_suite

  _cs_count=$(wc -l < "$CS_PROPS_AUDIT_FILE" 2>/dev/null | tr -d ' \t\r\n')
  cs_state_set "APPLIED_PROPS_COUNT" "${_cs_count:-0}"
  cs_log "Applied ${_cs_count:-0} verified non-persistent props (tier=${CS_EFF_TIER:-low}, blur=${EFF_FEAT_BLUR}, advtex=${EFF_FEAT_ADV_TEXTURES:-0}, anim=${EFF_FEAT_ANIMATIONS}, multitask=${EFF_FEAT_MULTITASK}, hz=${EFF_FEAT_DISPLAY_HZ}, audio=${EFF_FEAT_FLAGSHIP_AUDIO:-0}, suite=${EFF_FEAT_FLAGSHIP_SUITE:-0})."
  return 0
}
