#!/system/bin/sh
# CoreSurface - Zero-Gimmick User-Space Capability & Live Engine Verifier
# Pure POSIX sh. Verifies:
#   - Layer 1: applied resetprop values, XML bind-mount + tags, RRO overlays via
#              `cmd overlay list --user 0`, Video Depth marker, transactional settings.
#   - Layer 2: CoreSurfaceEngine APK install + REAL live runtime telemetry written by
#              SystemUI / MiuiHome / MiuiAod (AGSL shader compilation, bound hooks,
#              Thermal-Adaptive LOD tier, guarded Toasts/Recents, LivingFlow count).

CS_VERIFY_FILE="$CS_STATE_DIR/verify.state"
CS_OVERRIDDEN_PROPS_FILE="$CS_STATE_DIR/overridden_props.list"
CS_RRO_STAGED_LIST="$CS_STATE_DIR/rro_staged.list"

cs_verify_set() {
  _cs_vk=$1
  _cs_vv=$2
  printf '%s=%s\n' "$_cs_vk" "$_cs_vv" >> "$CS_VERIFY_TMP"
}

cs_verify_is_settings_err() {
  case "$1" in
    *Failure*|*Exception*|*Error*|*Binder*) return 0 ;;
    *) return 1 ;;
  esac
}

cs_verify_settings_get() {
  _cs_vsg_ns=$1
  _cs_vsg_key=$2
  CS_VSG_VAL=""

  _cs_vsg_out=$(settings --user 0 get "$_cs_vsg_ns" "$_cs_vsg_key" 2>&1)
  _cs_vsg_rc=$?
  _cs_vsg_line=$(printf '%s\n' "$_cs_vsg_out" | head -n 1 | tr -d '\r')
  if [ "$_cs_vsg_rc" -eq 0 ] && [ -n "$_cs_vsg_line" ] && ! cs_verify_is_settings_err "$_cs_vsg_line"; then
    CS_VSG_VAL="$_cs_vsg_line"
    return 0
  fi

  if command -v su >/dev/null 2>&1; then
    _cs_vsg_out=$(su 2000 -c "settings --user 0 get ${_cs_vsg_ns} ${_cs_vsg_key}" 2>&1)
    _cs_vsg_rc=$?
    _cs_vsg_line=$(printf '%s\n' "$_cs_vsg_out" | head -n 1 | tr -d '\r')
    if [ "$_cs_vsg_rc" -eq 0 ] && [ -n "$_cs_vsg_line" ] && ! cs_verify_is_settings_err "$_cs_vsg_line"; then
      CS_VSG_VAL="$_cs_vsg_line"
      return 0
    fi
  fi

  _cs_vsg_out=$(settings get "$_cs_vsg_ns" "$_cs_vsg_key" 2>&1)
  _cs_vsg_rc=$?
  _cs_vsg_line=$(printf '%s\n' "$_cs_vsg_out" | head -n 1 | tr -d '\r')
  if [ "$_cs_vsg_rc" -eq 0 ] && [ -n "$_cs_vsg_line" ] && ! cs_verify_is_settings_err "$_cs_vsg_line"; then
    CS_VSG_VAL="$_cs_vsg_line"
    return 0
  fi

  return 1
}

cs_telem_get() {
  _cs_tg_file=$1
  _cs_tg_key=$2
  if [ -r "$_cs_tg_file" ]; then
    awk -F '=' -v k="$_cs_tg_key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$_cs_tg_file" 2>/dev/null | tr -d '\r'
  fi
}

cs_verify_engine() {
  CS_V_ENGINE_INSTALLED="0"
  CS_V_ENGINE_ACTIVE="0"
  CS_V_ENGINE_AGSL="0"
  CS_V_ENGINE_LOD="N/A"
  CS_V_ENGINE_HOOKS=""
  CS_V_ENGINE_VIEWS=0
  CS_V_ENGINE_TOASTS=0
  CS_V_ENGINE_RECENTS=0
  CS_V_ENGINE_FLOWS=0

  # 1. Check whether CoreSurfaceEngine APK is installed
  if [ -n "${CORESURFACE_ENGINE_INSTALLED:-}" ]; then
    CS_V_ENGINE_INSTALLED="$CORESURFACE_ENGINE_INSTALLED"
  elif command -v pm >/dev/null 2>&1; then
    _cs_pm_out=$(pm path org.mystivara.coresurface.engine 2>&1 || true)
    if [ -z "$_cs_pm_out" ] || cs_verify_is_settings_err "$_cs_pm_out"; then
      if command -v su >/dev/null 2>&1; then
        _cs_pm_out=$(su 2000 -c "pm path org.mystivara.coresurface.engine" 2>&1 || true)
      fi
    fi
    case "$_cs_pm_out" in
      package:*) CS_V_ENGINE_INSTALLED="1" ;;
    esac
  fi

  # 2. Aggregate genuine live telemetry written by hooked processes (supports both user_de & user cache)
  _cs_t_sysui=${CORESURFACE_ENGINE_SYSUI_TELEM:-}
  if [ -z "$_cs_t_sysui" ]; then
    if [ -r /data/user_de/0/com.android.systemui/cache/coresurface_telemetry.prop ]; then
      _cs_t_sysui=/data/user_de/0/com.android.systemui/cache/coresurface_telemetry.prop
    else
      _cs_t_sysui=/data/user/0/com.android.systemui/cache/coresurface_telemetry.prop
    fi
  fi

  _cs_t_home=${CORESURFACE_ENGINE_HOME_TELEM:-}
  if [ -z "$_cs_t_home" ]; then
    if [ -r /data/user/0/com.miui.home/cache/coresurface_telemetry.prop ]; then
      _cs_t_home=/data/user/0/com.miui.home/cache/coresurface_telemetry.prop
    else
      _cs_t_home=/data/user_de/0/com.miui.home/cache/coresurface_telemetry.prop
    fi
  fi

  _cs_t_aod=${CORESURFACE_ENGINE_AOD_TELEM:-}
  if [ -z "$_cs_t_aod" ]; then
    if [ -r /data/user_de/0/com.miui.aod/cache/coresurface_telemetry.prop ]; then
      _cs_t_aod=/data/user_de/0/com.miui.aod/cache/coresurface_telemetry.prop
    else
      _cs_t_aod=/data/user/0/com.miui.aod/cache/coresurface_telemetry.prop
    fi
  fi

  for _cs_tf in "$_cs_t_sysui" "$_cs_t_home" "$_cs_t_aod"; do
    [ -r "$_cs_tf" ] || continue
    _cs_act=$(cs_telem_get "$_cs_tf" "ENGINE_ACTIVE")
    [ "$_cs_act" = "1" ] || continue

    CS_V_ENGINE_ACTIVE="1"
    _cs_agsl=$(cs_telem_get "$_cs_tf" "AGSL_COMPILED")
    if [ "$_cs_agsl" = "1" ]; then
      CS_V_ENGINE_AGSL="1"
    fi

    _cs_lod=$(cs_telem_get "$_cs_tf" "LOD_TIER")
    if [ -n "$_cs_lod" ] && [ "$CS_V_ENGINE_LOD" = "N/A" ]; then
      CS_V_ENGINE_LOD="$_cs_lod"
    fi

    _cs_hk=$(cs_telem_get "$_cs_tf" "HOOKS_BOUND")
    if [ -n "$_cs_hk" ]; then
      if [ -z "$CS_V_ENGINE_HOOKS" ]; then
        CS_V_ENGINE_HOOKS="$_cs_hk"
      else
        CS_V_ENGINE_HOOKS="${CS_V_ENGINE_HOOKS},${_cs_hk}"
      fi
    fi

    _cs_nv=$(cs_telem_get "$_cs_tf" "VIEWS_LUMINOUS")
    _cs_nt=$(cs_telem_get "$_cs_tf" "TOASTS_GUARDED")
    _cs_nr=$(cs_telem_get "$_cs_tf" "RECENTS_GUARDED")
    _cs_nf=$(cs_telem_get "$_cs_tf" "FLOW_ANIMS")
    cs_is_uint "$_cs_nv" && CS_V_ENGINE_VIEWS=$((CS_V_ENGINE_VIEWS + _cs_nv))
    cs_is_uint "$_cs_nt" && CS_V_ENGINE_TOASTS=$((CS_V_ENGINE_TOASTS + _cs_nt))
    cs_is_uint "$_cs_nr" && CS_V_ENGINE_RECENTS=$((CS_V_ENGINE_RECENTS + _cs_nr))
    cs_is_uint "$_cs_nf" && CS_V_ENGINE_FLOWS=$((CS_V_ENGINE_FLOWS + _cs_nf))
  done

  # 3. Map honest per-feature verification for Layer 2 Engine capabilities
  _cs_base_eng="skipped"
  if [ "$CS_V_ENGINE_INSTALLED" = "1" ] && [ "$CS_V_ENGINE_ACTIVE" != "1" ]; then
    _cs_base_eng="pending_lsposed"
  fi

  # FEAT_LUMINOUS_GLASS
  if [ "$CFG_FEAT_LUMINOUS_GLASS" = "0" ]; then
    CS_V_LUMINOUS_GLASS="disabled"
  elif [ "$EFF_FEAT_LUMINOUS_GLASS" != "1" ]; then
    CS_V_LUMINOUS_GLASS="skipped"
  elif [ "$CS_V_ENGINE_ACTIVE" = "1" ] && [ "$CS_V_ENGINE_AGSL" = "1" ]; then
    CS_V_LUMINOUS_GLASS="verified_active"
  elif [ "$CS_V_ENGINE_ACTIVE" = "1" ]; then
    CS_V_LUMINOUS_GLASS="ignored_by_rom"
  else
    CS_V_LUMINOUS_GLASS="$_cs_base_eng"
  fi

  # FEAT_LUMINOUS_TILT
  if [ "$CFG_FEAT_LUMINOUS_TILT" = "0" ]; then
    CS_V_LUMINOUS_TILT="disabled"
  elif [ "$EFF_FEAT_LUMINOUS_TILT" != "1" ]; then
    CS_V_LUMINOUS_TILT="skipped"
  elif [ "$CS_V_ENGINE_ACTIVE" = "1" ] && [ "$CS_V_ENGINE_AGSL" = "1" ]; then
    CS_V_LUMINOUS_TILT="verified_active"
  else
    CS_V_LUMINOUS_TILT="$_cs_base_eng"
  fi

  # FEAT_LIVING_FLOW
  if [ "$CFG_FEAT_LIVING_FLOW" = "0" ]; then
    CS_V_LIVING_FLOW="disabled"
  elif [ "$EFF_FEAT_LIVING_FLOW" != "1" ]; then
    CS_V_LIVING_FLOW="skipped"
  elif [ "$CS_V_ENGINE_ACTIVE" = "1" ]; then
    case ",$CS_V_ENGINE_HOOKS," in
      *,ControlCenterFlow,*|*,HomeLivingFlow,*|*,UnlockCascade,*)
        CS_V_LIVING_FLOW="verified_active"
        ;;
      *)
        CS_V_LIVING_FLOW="ignored_by_rom"
        ;;
    esac
  else
    CS_V_LIVING_FLOW="$_cs_base_eng"
  fi

  # FEAT_SURGICAL_GUARD
  if [ "$CFG_FEAT_SURGICAL_GUARD" = "0" ]; then
    CS_V_SURGICAL_GUARD="disabled"
  elif [ "$EFF_FEAT_SURGICAL_GUARD" != "1" ]; then
    CS_V_SURGICAL_GUARD="skipped"
  elif [ "$CS_V_ENGINE_ACTIVE" = "1" ]; then
    case ",$CS_V_ENGINE_HOOKS," in
      *,ToastGuard,*|*,RecentsGuard,*)
        CS_V_SURGICAL_GUARD="verified_active"
        ;;
      *)
        CS_V_SURGICAL_GUARD="ignored_by_rom"
        ;;
    esac
  else
    CS_V_SURGICAL_GUARD="$_cs_base_eng"
  fi

  # FEAT_THERMAL_LOD
  if [ "$CFG_FEAT_THERMAL_LOD" = "0" ]; then
    CS_V_THERMAL_LOD="disabled"
  elif [ "$EFF_FEAT_THERMAL_LOD" != "1" ]; then
    CS_V_THERMAL_LOD="skipped"
  elif [ "$CS_V_ENGINE_ACTIVE" = "1" ]; then
    CS_V_THERMAL_LOD="verified_active"
  else
    CS_V_THERMAL_LOD="$_cs_base_eng"
  fi
}

cs_verify_xml_mount() {
  _cs_mounts=${CORESURFACE_PROC_MOUNTS:-/proc/mounts}
  _cs_xml_status=$(cs_state_get "XML_STATUS")
  _cs_xml_source=$(cs_state_get "XML_SOURCE")

  if [ "$CFG_FEAT_XML_PATCHER" = "0" ]; then
    CS_V_XML_MOUNT="disabled"
    CS_V_XML_FEAT="disabled"
    return 0
  fi

  if [ "$EFF_FEAT_XML_PATCHER" != "1" ] || [ "$_cs_xml_status" = "skipped" ] || [ -z "$_cs_xml_source" ] || [ "$_cs_xml_source" = "none" ]; then
    CS_V_XML_MOUNT="skipped"
    CS_V_XML_FEAT="skipped"
    return 0
  fi

  if [ -r "$_cs_mounts" ] && awk -v target="$_cs_xml_source" '$2 == target { found=1; exit } END { exit(found ? 0 : 1) }' "$_cs_mounts" 2>/dev/null; then
    CS_V_XML_MOUNT="active"
    CS_V_XML_FEAT="verified_active"
  else
    CS_V_XML_MOUNT="not_mounted"
    CS_V_XML_FEAT="ignored_by_rom"
  fi
}

cs_verify_xml_tag_feature() {
  _cs_xt_cfg=$1
  _cs_xt_eff=$2
  _cs_xt_needle=$3
  _cs_xt_xml="$CS_STATE_DIR/work/device_features.xml"
  CS_XT_RESULT="skipped"

  if [ "$_cs_xt_cfg" = "0" ]; then
    CS_XT_RESULT="disabled"
    return 0
  fi
  if [ "$_cs_xt_eff" != "1" ]; then
    CS_XT_RESULT="skipped"
    return 0
  fi
  if [ "$CS_V_XML_MOUNT" = "active" ] && [ -r "$_cs_xt_xml" ] && grep -F -q "$_cs_xt_needle" "$_cs_xt_xml" 2>/dev/null; then
    CS_XT_RESULT="verified_active"
  elif [ "$CS_V_XML_MOUNT" = "not_mounted" ]; then
    CS_XT_RESULT="ignored_by_rom"
  else
    CS_XT_RESULT="skipped"
  fi
}

cs_verify_rro_overlays() {
  CS_V_RRO_ACTIVE=0
  CS_V_RRO_TOTAL=0
  _cs_live_ov_dir=${CORESURFACE_LIVE_OVERLAY_DIR:-/product/overlay}

  if [ "$CFG_FEAT_RRO_OVERLAYS" = "0" ]; then
    CS_V_RRO_FEAT="disabled"
    return 0
  fi

  if [ "$EFF_FEAT_RRO_OVERLAYS" != "1" ] || [ ! -s "$CS_RRO_STAGED_LIST" ]; then
    CS_V_RRO_FEAT="skipped"
    return 0
  fi

  _cs_any_mounted=0
  while IFS='|' read -r _cs_mapk _cs_mpkg || [ -n "$_cs_mapk" ]; do
    [ -n "$_cs_mapk" ] || continue
    if [ -f "$_cs_live_ov_dir/$_cs_mapk" ]; then
      _cs_any_mounted=1
      break
    fi
  done < "$CS_RRO_STAGED_LIST"

  if [ "$_cs_any_mounted" -eq 0 ]; then
    cs_log "Verifier: staged RRO APKs not mounted at ${_cs_live_ov_dir} (install meta-overlayfs metamodule in KernelSU-Next)."
    CS_V_RRO_FEAT="skipped"
    return 0
  fi

  if ! command -v cmd >/dev/null 2>&1; then
    CS_V_RRO_FEAT="skipped"
    return 0
  fi

  _cs_ov_out=$(cmd overlay list --user 0 2>&1 || true)
  if [ -z "$_cs_ov_out" ] || cs_verify_is_settings_err "$_cs_ov_out"; then
    if command -v su >/dev/null 2>&1; then
      _cs_ov_out=$(su 2000 -c "cmd overlay list --user 0" 2>&1 || true)
    fi
  fi
  if [ -z "$_cs_ov_out" ] || cs_verify_is_settings_err "$_cs_ov_out"; then
    _cs_ov_out=$(cmd overlay list 2>&1 || true)
  fi
  if [ -z "$_cs_ov_out" ] || cs_verify_is_settings_err "$_cs_ov_out"; then
    cs_log "Verifier: cmd overlay list unavailable or Binder error; skipping RRO verification."
    CS_V_RRO_FEAT="skipped"
    return 0
  fi

  while IFS='|' read -r _cs_rapk _cs_rpkg || [ -n "$_cs_rapk" ]; do
    [ -n "$_cs_rpkg" ] || continue
    if printf '%s\n' "$_cs_ov_out" | grep -F -q "$_cs_rpkg"; then
      CS_V_RRO_TOTAL=$((CS_V_RRO_TOTAL + 1))
      if printf '%s\n' "$_cs_ov_out" | grep -F -q "[x] $_cs_rpkg"; then
        CS_V_RRO_ACTIVE=$((CS_V_RRO_ACTIVE + 1))
      fi
    fi
  done < "$CS_RRO_STAGED_LIST"

  if [ "$CS_V_RRO_TOTAL" -eq 0 ]; then
    CS_V_RRO_FEAT="skipped"
  elif [ "$CS_V_RRO_ACTIVE" -gt 0 ]; then
    CS_V_RRO_FEAT="verified_active"
  else
    CS_V_RRO_FEAT="ignored_by_rom"
  fi
}

cs_verify_video_depth() {
  _cs_vd_path=${CORESURFACE_VIDEO_DEPTH_PATH:-/product/media/wallpaper/sysui_editor_wallpaper_group/enable_video_depth}
  if [ "$CFG_FEAT_VIDEO_DEPTH" = "0" ]; then
    CS_V_VIDEO_DEPTH="disabled"
    return 0
  fi
  if [ "$EFF_FEAT_VIDEO_DEPTH" != "1" ]; then
    CS_V_VIDEO_DEPTH="skipped"
    return 0
  fi
  if [ -e "$_cs_vd_path" ]; then
    CS_V_VIDEO_DEPTH="verified_active"
  else
    CS_V_VIDEO_DEPTH="skipped"
  fi
}

# Verify a single feature's applied props (and settings if any).
cs_verify_feature() {
  _cs_vf_name=$1
  _cs_vf_cfg=$2
  _cs_vf_eff=$3
  CS_VF_RESULT="skipped"

  if [ "$_cs_vf_cfg" = "0" ]; then
    CS_VF_RESULT="disabled"
    return 0
  fi

  if [ "$_cs_vf_eff" != "1" ]; then
    CS_VF_RESULT="skipped"
    return 0
  fi

  _cs_vf_checked=0
  _cs_vf_mismatch=0

  if [ -r "$CS_PROPS_AUDIT_FILE" ]; then
    while IFS='|' read -r _cs_pf _cs_kv || [ -n "$_cs_pf" ]; do
      [ "$_cs_pf" = "$_cs_vf_name" ] || continue
      _cs_pk=${_cs_kv%%=*}
      _cs_pv=${_cs_kv#*=}
      [ -n "$_cs_pk" ] || continue

      _cs_actual=$(cs_getprop "$_cs_pk")
      _cs_vf_checked=$((_cs_vf_checked + 1))
      CS_V_PROPS_TOTAL=$((CS_V_PROPS_TOTAL + 1))

      if [ "$_cs_actual" = "$_cs_pv" ]; then
        CS_V_PROPS_MATCHED=$((CS_V_PROPS_MATCHED + 1))
      else
        _cs_vf_mismatch=$((_cs_vf_mismatch + 1))
        CS_V_PROPS_OVERRIDDEN=$((CS_V_PROPS_OVERRIDDEN + 1))
        printf '%s|%s|%s|%s\n' "$_cs_vf_name" "$_cs_pk" "$_cs_pv" "${_cs_actual:-<empty>}" >> "$CS_OVERRIDDEN_PROPS_FILE"
      fi
    done < "$CS_PROPS_AUDIT_FILE"
  fi

  if [ "$CS_V_SETTINGS_OK" = "1" ] && [ -r "$CS_SETTINGS_APPLIED_FILE" ]; then
    while IFS='|' read -r _cs_sf _cs_sns _cs_skv || [ -n "$_cs_sf" ]; do
      [ "$_cs_sf" = "$_cs_vf_name" ] || continue
      _cs_sk=${_cs_skv%%=*}
      _cs_sv=${_cs_skv#*=}
      if [ -z "$_cs_sns" ] || [ -z "$_cs_sk" ]; then
        continue
      fi

      if ! cs_verify_settings_get "$_cs_sns" "$_cs_sk"; then
        CS_V_SETTINGS_OK="0"
        cs_log "Verifier: settings service rejected Binder call; skipping remaining settings checks."
        break
      fi

      _cs_vf_checked=$((_cs_vf_checked + 1))
      if [ "$CS_VSG_VAL" != "$_cs_sv" ]; then
        _cs_vf_mismatch=$((_cs_vf_mismatch + 1))
        printf '%s|settings:%s/%s|%s|%s\n' "$_cs_vf_name" "$_cs_sns" "$_cs_sk" "$_cs_sv" "${CS_VSG_VAL:-<empty>}" >> "$CS_OVERRIDDEN_PROPS_FILE"
      fi
    done < "$CS_SETTINGS_APPLIED_FILE"
  fi

  if [ "$_cs_vf_checked" -eq 0 ]; then
    CS_VF_RESULT="skipped"
  elif [ "$_cs_vf_mismatch" -gt 0 ]; then
    CS_VF_RESULT="ignored_by_rom"
  else
    CS_VF_RESULT="verified_active"
  fi
}

cs_score_tally() {
  case "$1" in
    verified_active)
      CS_V_FEAT_EVALUATED=$((CS_V_FEAT_EVALUATED + 1))
      CS_V_FEAT_VERIFIED=$((CS_V_FEAT_VERIFIED + 1))
      ;;
    ignored_by_rom)
      CS_V_FEAT_EVALUATED=$((CS_V_FEAT_EVALUATED + 1))
      ;;
  esac
}

cs_verifier_run() {
  cs_watchdog_init_dir || return 1

  CS_V_PROPS_TOTAL=0
  CS_V_PROPS_MATCHED=0
  CS_V_PROPS_OVERRIDDEN=0
  CS_V_XML_MOUNT="skipped"
  CS_V_XML_FEAT="skipped"
  CS_V_RRO_FEAT="skipped"
  CS_V_RRO_ACTIVE=0
  CS_V_RRO_TOTAL=0
  CS_V_VIDEO_DEPTH="skipped"
  CS_V_FEAT_EVALUATED=0
  CS_V_FEAT_VERIFIED=0
  CS_V_SETTINGS_OK="0"
  if command -v settings >/dev/null 2>&1; then
    CS_V_SETTINGS_OK="1"
  fi

  : > "$CS_OVERRIDDEN_PROPS_FILE"
  CS_VERIFY_TMP="$CS_VERIFY_FILE.tmp.$$"
  : > "$CS_VERIFY_TMP"

  cs_verify_engine
  cs_verify_xml_mount
  cs_verify_rro_overlays
  cs_verify_video_depth

  cs_verify_xml_tag_feature "$CFG_FEAT_COLOR_EXPERT" "$EFF_FEAT_COLOR_EXPERT" '<bool name="support_display_expert_mode">true</bool>'
  _cs_v_color=$CS_XT_RESULT
  cs_verify_xml_tag_feature "$CFG_FEAT_GALLERY_PRO" "$EFF_FEAT_GALLERY_PRO" '<bool name="gallery_support_video_compress">true</bool>'
  _cs_v_gallery=$CS_XT_RESULT
  cs_verify_xml_tag_feature "$CFG_FEAT_AOD_UNLOCK" "$EFF_FEAT_AOD_UNLOCK" '<bool name="support_aod_aon">true</bool>'
  _cs_v_aod=$CS_XT_RESULT
  if [ "$EFF_FEAT_AOD_UNLOCK" = "1" ] && [ "$_cs_v_aod" != "verified_active" ] && [ "$CS_V_ENGINE_ACTIVE" = "1" ]; then
    case ",$CS_V_ENGINE_HOOKS," in
      *,KeyguardAodFlow,*|*,AodLivingFlow,*) _cs_v_aod="verified_active" ;;
    esac
  fi

  cs_verify_feature "FEAT_BLUR" "$CFG_FEAT_BLUR" "$EFF_FEAT_BLUR"
  _cs_v_blur=$CS_VF_RESULT
  cs_verify_feature "FEAT_ANIMATIONS" "$CFG_FEAT_ANIMATIONS" "$EFF_FEAT_ANIMATIONS"
  _cs_v_anim=$CS_VF_RESULT
  cs_verify_feature "FEAT_MULTITASK" "$CFG_FEAT_MULTITASK" "$EFF_FEAT_MULTITASK"
  _cs_v_multi=$CS_VF_RESULT
  cs_verify_feature "FEAT_DISPLAY_HZ" "$CFG_FEAT_DISPLAY_HZ" "$EFF_FEAT_DISPLAY_HZ"
  _cs_v_hz=$CS_VF_RESULT

  for _cs_s in \
    "$CS_V_LUMINOUS_GLASS" "$CS_V_LUMINOUS_TILT" "$CS_V_LIVING_FLOW" \
    "$CS_V_SURGICAL_GUARD" "$CS_V_THERMAL_LOD" \
    "$_cs_v_blur" "$_cs_v_anim" "$CS_V_XML_FEAT" "$CS_V_RRO_FEAT" \
    "$CS_V_VIDEO_DEPTH" "$_cs_v_multi" "$_cs_v_hz" \
    "$_cs_v_color" "$_cs_v_gallery" "$_cs_v_aod"
  do
    cs_score_tally "$_cs_s"
  done

  if [ "$CS_V_FEAT_EVALUATED" -gt 0 ]; then
    _cs_compat_pct=$((CS_V_FEAT_VERIFIED * 100 / CS_V_FEAT_EVALUATED))
  else
    _cs_compat_pct=0
  fi

  cs_verify_set "VERIFY_ENGINE_INSTALLED" "$CS_V_ENGINE_INSTALLED"
  cs_verify_set "VERIFY_ENGINE_ACTIVE" "$CS_V_ENGINE_ACTIVE"
  cs_verify_set "VERIFY_ENGINE_AGSL" "$CS_V_ENGINE_AGSL"
  cs_verify_set "VERIFY_ENGINE_LOD" "$CS_V_ENGINE_LOD"
  cs_verify_set "VERIFY_ENGINE_HOOKS" "$CS_V_ENGINE_HOOKS"
  cs_verify_set "VERIFY_ENGINE_VIEWS" "$CS_V_ENGINE_VIEWS"
  cs_verify_set "VERIFY_ENGINE_TOASTS" "$CS_V_ENGINE_TOASTS"
  cs_verify_set "VERIFY_ENGINE_RECENTS" "$CS_V_ENGINE_RECENTS"
  cs_verify_set "VERIFY_ENGINE_FLOWS" "$CS_V_ENGINE_FLOWS"

  cs_verify_set "VERIFY_FEAT_LUMINOUS_GLASS" "$CS_V_LUMINOUS_GLASS"
  cs_verify_set "VERIFY_FEAT_LUMINOUS_TILT" "$CS_V_LUMINOUS_TILT"
  cs_verify_set "VERIFY_FEAT_LIVING_FLOW" "$CS_V_LIVING_FLOW"
  cs_verify_set "VERIFY_FEAT_SURGICAL_GUARD" "$CS_V_SURGICAL_GUARD"
  cs_verify_set "VERIFY_FEAT_THERMAL_LOD" "$CS_V_THERMAL_LOD"
  cs_verify_set "VERIFY_FEAT_BLUR" "$_cs_v_blur"
  cs_verify_set "VERIFY_FEAT_ANIMATIONS" "$_cs_v_anim"
  cs_verify_set "VERIFY_FEAT_XML_PATCHER" "$CS_V_XML_FEAT"
  cs_verify_set "VERIFY_FEAT_RRO_OVERLAYS" "$CS_V_RRO_FEAT"
  cs_verify_set "VERIFY_FEAT_VIDEO_DEPTH" "$CS_V_VIDEO_DEPTH"
  cs_verify_set "VERIFY_FEAT_MULTITASK" "$_cs_v_multi"
  cs_verify_set "VERIFY_FEAT_DISPLAY_HZ" "$_cs_v_hz"
  cs_verify_set "VERIFY_FEAT_COLOR_EXPERT" "$_cs_v_color"
  cs_verify_set "VERIFY_FEAT_GALLERY_PRO" "$_cs_v_gallery"
  cs_verify_set "VERIFY_FEAT_AOD_UNLOCK" "$_cs_v_aod"

  cs_verify_set "VERIFY_XML_MOUNT" "$CS_V_XML_MOUNT"
  cs_verify_set "VERIFY_RRO_ACTIVE" "$CS_V_RRO_ACTIVE"
  cs_verify_set "VERIFY_RRO_TOTAL" "$CS_V_RRO_TOTAL"
  cs_verify_set "VERIFY_PROPS_TOTAL" "$CS_V_PROPS_TOTAL"
  cs_verify_set "VERIFY_PROPS_MATCHED" "$CS_V_PROPS_MATCHED"
  cs_verify_set "VERIFY_PROPS_OVERRIDDEN" "$CS_V_PROPS_OVERRIDDEN"
  cs_verify_set "VERIFY_FEAT_VERIFIED" "$CS_V_FEAT_VERIFIED"
  cs_verify_set "VERIFY_FEAT_EVALUATED" "$CS_V_FEAT_EVALUATED"
  cs_verify_set "COMPAT_SCORE_PCT" "$_cs_compat_pct"

  mv -f "$CS_VERIFY_TMP" "$CS_VERIFY_FILE"
  cs_log "Verifier: score=${_cs_compat_pct}% (${CS_V_FEAT_VERIFIED}/${CS_V_FEAT_EVALUATED}), props=${CS_V_PROPS_MATCHED}/${CS_V_PROPS_TOTAL}, xml=${CS_V_XML_MOUNT}, rro=${CS_V_RRO_ACTIVE}/${CS_V_RRO_TOTAL}, engine=${CS_V_ENGINE_ACTIVE} (agsl=${CS_V_ENGINE_AGSL}, lod=${CS_V_ENGINE_LOD})."
  return 0
}
