#!/system/bin/sh
# CoreSurface - Zero-Gimmick Standalone User-Space Capability Verifier
# Pure POSIX sh. Verifies:
#   - Applied non-persistent resetprop values, XML bind-mount + tags, RRO overlays via
#     `cmd overlay list --user 0`, Video Depth marker, and transactional settings.

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

  if command -v cs_settings_get >/dev/null 2>&1; then
    if cs_settings_get "$_cs_vsg_ns" "$_cs_vsg_key"; then
      CS_VSG_VAL="$CS_SETTINGS_READ_VAL"
      return 0
    fi
    return 1
  fi

  _cs_vsg_out=$(settings --user 0 get "$_cs_vsg_ns" "$_cs_vsg_key" 2>&1)
  _cs_vsg_rc=$?
  _cs_vsg_line=$(printf '%s\n' "$_cs_vsg_out" | head -n 1 | tr -d '\r')
  if [ "$_cs_vsg_rc" -eq 0 ] && [ -n "$_cs_vsg_line" ] && ! cs_verify_is_settings_err "$_cs_vsg_line"; then
    CS_VSG_VAL="$_cs_vsg_line"
    return 0
  fi

  if command -v su >/dev/null 2>&1; then
    _cs_vsg_out=$(su 2000 -c "settings --user 0 get '${_cs_vsg_ns}' '${_cs_vsg_key}'" 2>&1)
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
  CS_V_RRO_INACTIVE=""
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

  _cs_ov_out=${CS_RRO_OV_LIST_CACHE:-}
  if [ -z "$_cs_ov_out" ] || cs_verify_is_settings_err "$_cs_ov_out"; then
    _cs_ov_out=$(cmd overlay list --user 0 2>&1 || true)
  fi
  if [ -z "$_cs_ov_out" ] || cs_verify_is_settings_err "$_cs_ov_out"; then
    if command -v su >/dev/null 2>&1; then
      _cs_ov_out=$(su 2000 -c "cmd overlay list --user 0" 2>&1 || true)
    fi
  fi
  if [ -z "$_cs_ov_out" ] || cs_verify_is_settings_err "$_cs_ov_out"; then
    if command -v su >/dev/null 2>&1; then
      _cs_ov_out=$(su --context u:r:shell:s0 2000 -c "cmd overlay list --user 0" 2>&1 || true)
    fi
  fi
  if [ -z "$_cs_ov_out" ] || cs_verify_is_settings_err "$_cs_ov_out"; then
    for _cs_vbb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
      if [ -x "$_cs_vbb" ]; then
        _cs_ov_out=$("$_cs_vbb" setuidgid 2000 cmd overlay list --user 0 2>&1 || true)
        break
      fi
    done
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
      else
        _cs_short=${_cs_rpkg##*.}
        if [ -z "$CS_V_RRO_INACTIVE" ]; then
          CS_V_RRO_INACTIVE="$_cs_short"
        else
          CS_V_RRO_INACTIVE="${CS_V_RRO_INACTIVE},${_cs_short}"
        fi
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

# Build a single-pass getprop snapshot to avoid spawning 60+ getprop subshells on Android.
cs_verify_init_props_snapshot() {
  CS_V_SNAP_FILE="$CS_STATE_DIR/.getprop_snap.$$"
  CS_V_SNAP_OK=0
  if command -v getprop >/dev/null 2>&1; then
    getprop 2>/dev/null | awk '
      /^\[[^\]]+\]: \[.*\]$/ {
        line = $0
        sub(/^\[/, "", line)
        idx = index(line, "]: [")
        if (idx > 0) {
          k = substr(line, 1, idx - 1)
          v = substr(line, idx + 4)
          sub(/\]$/, "", v)
          print k "=" v
        }
      }
    ' > "$CS_V_SNAP_FILE" 2>/dev/null || true
    if [ -s "$CS_V_SNAP_FILE" ]; then
      CS_V_SNAP_OK=1
    else
      rm -f "$CS_V_SNAP_FILE" 2>/dev/null || true
    fi
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
    if [ "${CS_V_SNAP_OK:-0}" = "1" ] && [ -r "$CS_V_SNAP_FILE" ]; then
      _cs_vf_stats=$(awk -v feat="$_cs_vf_name" -v ovfile="$CS_OVERRIDDEN_PROPS_FILE" '
        NR == FNR {
          eq = index($0, "=")
          if (eq > 0) snap[substr($0, 1, eq - 1)] = substr($0, eq + 1)
          next
        }
        {
          bar = index($0, "|")
          if (bar <= 0) next
          f = substr($0, 1, bar - 1)
          if (f != feat) next
          kv = substr($0, bar + 1)
          eq = index(kv, "=")
          if (eq <= 0) next
          pk = substr(kv, 1, eq - 1)
          pv = substr(kv, eq + 1)
          if (pk == "") next
          checked++
          actual = (pk in snap) ? snap[pk] : ""
          if (actual == pv) {
            matched++
          } else {
            mismatch++
            print feat "|" pk "|" pv "|" (actual == "" ? "<empty>" : actual) >> ovfile
          }
        }
        END { printf "%d %d %d\n", checked + 0, matched + 0, mismatch + 0 }
      ' "$CS_V_SNAP_FILE" "$CS_PROPS_AUDIT_FILE" 2>/dev/null || printf '0 0 0\n')
      _cs_vf_checked=${_cs_vf_stats%% *}
      _cs_vf_rest=${_cs_vf_stats#* }
      _cs_vf_matched=${_cs_vf_rest%% *}
      _cs_vf_mismatch=${_cs_vf_rest#* }
      CS_V_PROPS_TOTAL=$((CS_V_PROPS_TOTAL + _cs_vf_checked))
      CS_V_PROPS_MATCHED=$((CS_V_PROPS_MATCHED + _cs_vf_matched))
      CS_V_PROPS_OVERRIDDEN=$((CS_V_PROPS_OVERRIDDEN + _cs_vf_mismatch))
    else
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
        if command -v cs_settings_binder_mark_blocked >/dev/null 2>&1; then
          cs_settings_binder_mark_blocked
        fi
        cs_log "Verifier: settings service rejected Binder call (${CS_SETTINGS_LAST_ERR:-unknown}); skipping remaining settings checks."
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
  CS_V_RRO_INACTIVE=""
  CS_V_VIDEO_DEPTH="skipped"
  CS_V_FEAT_EVALUATED=0
  CS_V_FEAT_VERIFIED=0
  CS_V_SETTINGS_OK="0"
  if command -v settings >/dev/null 2>&1 && [ "${CS_SETTINGS_BINDER_FAILED:-0}" != "1" ]; then
    if command -v cs_settings_binder_is_cached_blocked >/dev/null 2>&1 && cs_settings_binder_is_cached_blocked; then
      CS_V_SETTINGS_OK="0"
    else
      CS_V_SETTINGS_OK="1"
    fi
  fi

  : > "$CS_OVERRIDDEN_PROPS_FILE"
  CS_VERIFY_TMP="$CS_VERIFY_FILE.tmp.$$"
  : > "$CS_VERIFY_TMP"

  cs_verify_init_props_snapshot
  cs_verify_xml_mount
  cs_verify_rro_overlays
  cs_verify_video_depth

  cs_verify_xml_tag_feature "$CFG_FEAT_COLOR_EXPERT" "$EFF_FEAT_COLOR_EXPERT" '<bool name="support_display_expert_mode">true</bool>'
  _cs_v_color=$CS_XT_RESULT
  cs_verify_xml_tag_feature "$CFG_FEAT_AOD_UNLOCK" "$EFF_FEAT_AOD_UNLOCK" '<bool name="is_only_support_keycode_goto">false</bool>'
  _cs_v_aod=$CS_XT_RESULT

  cs_verify_feature "FEAT_BLUR" "$CFG_FEAT_BLUR" "$EFF_FEAT_BLUR"
  _cs_v_blur=$CS_VF_RESULT
  cs_verify_feature "FEAT_ANIMATIONS" "$CFG_FEAT_ANIMATIONS" "$EFF_FEAT_ANIMATIONS"
  _cs_v_anim=$CS_VF_RESULT
  cs_verify_feature "FEAT_MULTITASK" "$CFG_FEAT_MULTITASK" "$EFF_FEAT_MULTITASK"
  _cs_v_multi=$CS_VF_RESULT
  cs_verify_feature "FEAT_DISPLAY_HZ" "$CFG_FEAT_DISPLAY_HZ" "$EFF_FEAT_DISPLAY_HZ"
  _cs_v_hz=$CS_VF_RESULT
  cs_verify_feature "FEAT_FLAGSHIP_AUDIO" "$CFG_FEAT_FLAGSHIP_AUDIO" "$EFF_FEAT_FLAGSHIP_AUDIO"
  _cs_v_audio=$CS_VF_RESULT
  cs_verify_feature "FEAT_FLAGSHIP_SUITE" "$CFG_FEAT_FLAGSHIP_SUITE" "$EFF_FEAT_FLAGSHIP_SUITE"
  _cs_v_suite=$CS_VF_RESULT

  # Honest Camera Pro Engine & Leica Bridge verification
  _cs_v_cam_pro="skipped"
  if [ "${CFG_FEAT_CAMERA_PRO:-auto}" = "0" ]; then
    _cs_v_cam_pro="disabled"
  elif [ "${CS_CAM_LEICA_SOURCE:-none}" = "native" ] || [ "${CS_EFF_TIER:-low}" = "motion_only" ]; then
    _cs_v_cam_pro="native_passthrough"
  elif [ "${EFF_FEAT_CAMERA_PRO:-0}" = "1" ]; then
    cs_verify_xml_tag_feature "${CFG_FEAT_CAMERA_PRO:-auto}" "${EFF_FEAT_CAMERA_PRO:-0}" '<bool name="support_camera_shutter_sound_control">true</bool>'
    _cs_v_cam_xml=$CS_XT_RESULT
    cs_verify_feature "FEAT_CAMERA_PRO" "${CFG_FEAT_CAMERA_PRO:-auto}" "${EFF_FEAT_CAMERA_PRO:-0}"
    _cs_v_cam_prop=$CS_VF_RESULT
    if [ "$_cs_v_cam_xml" = "ignored_by_rom" ] || [ "$_cs_v_cam_prop" = "ignored_by_rom" ]; then
      _cs_v_cam_pro="ignored_by_rom"
    elif [ "$_cs_v_cam_xml" = "verified_active" ] || [ "$_cs_v_cam_prop" = "verified_active" ]; then
      _cs_v_cam_pro="verified_active"
    else
      _cs_v_cam_pro="skipped"
    fi
  fi

  _cs_v_leica="companion_missing"
  if [ "${CS_CAM_WATCHDOG_STATUS:-healthy}" = "auto_reverted" ]; then
    _cs_v_leica="auto_reverted"
  elif [ "${CFG_FEAT_LEICA_BRIDGE:-auto}" = "0" ]; then
    _cs_v_leica="disabled"
  elif [ "${CS_CAM_LEICA_SOURCE:-none}" = "native" ]; then
    _cs_v_leica="native_passthrough"
  elif [ "${CS_CAM_LEICA_SOURCE:-none}" = "companion" ]; then
    _cs_v_leica="companion_active"
  else
    _cs_v_leica="companion_missing"
  fi

  rm -f "${CS_V_SNAP_FILE:-}" 2>/dev/null || true

  for _cs_s in \
    "$_cs_v_blur" "$_cs_v_anim" "$CS_V_XML_FEAT" "$CS_V_RRO_FEAT" \
    "$CS_V_VIDEO_DEPTH" "$_cs_v_multi" "$_cs_v_hz" \
    "$_cs_v_color" "$_cs_v_aod" "$_cs_v_audio" "$_cs_v_suite" \
    "$_cs_v_cam_pro"
  do
    cs_score_tally "$_cs_s"
  done

  if [ "$CS_V_FEAT_EVALUATED" -gt 0 ]; then
    _cs_compat_pct=$((CS_V_FEAT_VERIFIED * 100 / CS_V_FEAT_EVALUATED))
  else
    _cs_compat_pct=0
  fi

  cs_verify_set "VERIFY_FEAT_BLUR" "$_cs_v_blur"
  cs_verify_set "VERIFY_FEAT_ANIMATIONS" "$_cs_v_anim"
  cs_verify_set "VERIFY_FEAT_XML_PATCHER" "$CS_V_XML_FEAT"
  cs_verify_set "VERIFY_FEAT_RRO_OVERLAYS" "$CS_V_RRO_FEAT"
  cs_verify_set "VERIFY_FEAT_VIDEO_DEPTH" "$CS_V_VIDEO_DEPTH"
  cs_verify_set "VERIFY_FEAT_MULTITASK" "$_cs_v_multi"
  cs_verify_set "VERIFY_FEAT_DISPLAY_HZ" "$_cs_v_hz"
  cs_verify_set "VERIFY_FEAT_COLOR_EXPERT" "$_cs_v_color"
  cs_verify_set "VERIFY_FEAT_AOD_UNLOCK" "$_cs_v_aod"
  cs_verify_set "VERIFY_FEAT_FLAGSHIP_AUDIO" "$_cs_v_audio"
  cs_verify_set "VERIFY_FEAT_FLAGSHIP_SUITE" "$_cs_v_suite"
  cs_verify_set "VERIFY_FEAT_CAMERA_PRO" "$_cs_v_cam_pro"
  cs_verify_set "VERIFY_FEAT_LEICA_BRIDGE" "$_cs_v_leica"

  cs_verify_set "VERIFY_XML_MOUNT" "$CS_V_XML_MOUNT"
  cs_verify_set "VERIFY_RRO_ACTIVE" "$CS_V_RRO_ACTIVE"
  cs_verify_set "VERIFY_RRO_TOTAL" "$CS_V_RRO_TOTAL"
  cs_verify_set "VERIFY_RRO_INACTIVE" "$CS_V_RRO_INACTIVE"
  cs_verify_set "VERIFY_PROPS_TOTAL" "$CS_V_PROPS_TOTAL"
  cs_verify_set "VERIFY_PROPS_MATCHED" "$CS_V_PROPS_MATCHED"
  cs_verify_set "VERIFY_PROPS_OVERRIDDEN" "$CS_V_PROPS_OVERRIDDEN"
  cs_verify_set "VERIFY_FEAT_VERIFIED" "$CS_V_FEAT_VERIFIED"
  cs_verify_set "VERIFY_FEAT_EVALUATED" "$CS_V_FEAT_EVALUATED"
  cs_verify_set "COMPAT_SCORE_PCT" "$_cs_compat_pct"

  mv -f "$CS_VERIFY_TMP" "$CS_VERIFY_FILE"
  _cs_ov_note=""
  if [ "$CS_V_PROPS_OVERRIDDEN" -gt 0 ] && [ -s "$CS_OVERRIDDEN_PROPS_FILE" ]; then
    _cs_ov_keys=$(awk -F '|' 'NR <= 4 { if (s != "") s = s ","; s = s $2 } END { print s }' "$CS_OVERRIDDEN_PROPS_FILE" 2>/dev/null || true)
    [ -n "$_cs_ov_keys" ] && _cs_ov_note=" overridden=[${_cs_ov_keys}]"
  fi
  _cs_rro_note=""
  [ -n "$CS_V_RRO_INACTIVE" ] && _cs_rro_note=" inactive=[${CS_V_RRO_INACTIVE}]"
  cs_log "Verifier: score=${_cs_compat_pct}% (${CS_V_FEAT_VERIFIED}/${CS_V_FEAT_EVALUATED}), tier=${CS_EFF_TIER:-low}, props=${CS_V_PROPS_MATCHED}/${CS_V_PROPS_TOTAL}${_cs_ov_note}, xml=${CS_V_XML_MOUNT}, rro=${CS_V_RRO_ACTIVE}/${CS_V_RRO_TOTAL}${_cs_rro_note}."
  return 0
}
