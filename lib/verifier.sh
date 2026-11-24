#!/system/bin/sh
# CoreSurface - User-Space Capability Verifier
# Pure POSIX sh. Verifies applied resetprop values, XML bind-mount, RRO overlays
# via `cmd overlay list --user 0`, and settings after boot completion + SystemUI health.

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

  _cs_vsg_out=$(settings --user 0 get "$_cs_vsg_ns" "$_cs_vsg_key" 2>&1 | head -n 1 | tr -d '\r' || true)
  if [ -n "$_cs_vsg_out" ] && ! cs_verify_is_settings_err "$_cs_vsg_out"; then
    CS_VSG_VAL="$_cs_vsg_out"
    return 0
  fi

  _cs_vsg_out=$(settings get "$_cs_vsg_ns" "$_cs_vsg_key" 2>&1 | head -n 1 | tr -d '\r' || true)
  if [ -n "$_cs_vsg_out" ] && ! cs_verify_is_settings_err "$_cs_vsg_out"; then
    CS_VSG_VAL="$_cs_vsg_out"
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

# Verify staged clean-room RRO overlays using `cmd overlay list --user 0`.
# Sets: CS_V_RRO_FEAT, CS_V_RRO_ACTIVE, CS_V_RRO_TOTAL
cs_verify_rro_overlays() {
  CS_V_RRO_ACTIVE=0
  CS_V_RRO_TOTAL=0

  if [ "$CFG_FEAT_RRO_OVERLAYS" = "0" ]; then
    CS_V_RRO_FEAT="disabled"
    return 0
  fi

  if [ "$EFF_FEAT_RRO_OVERLAYS" != "1" ] || [ ! -s "$CS_RRO_STAGED_LIST" ]; then
    CS_V_RRO_FEAT="skipped"
    return 0
  fi

  if ! command -v cmd >/dev/null 2>&1; then
    CS_V_RRO_FEAT="skipped"
    return 0
  fi

  _cs_ov_out=$(cmd overlay list --user 0 2>&1 || true)
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
    CS_V_RRO_TOTAL=$((CS_V_RRO_TOTAL + 1))
    if printf '%s\n' "$_cs_ov_out" | grep -F -q "[x] $_cs_rpkg"; then
      CS_V_RRO_ACTIVE=$((CS_V_RRO_ACTIVE + 1))
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

# Verify a single feature's applied props (and settings if any).
# Sets CS_VF_RESULT to: verified_active | ignored_by_rom | skipped | disabled
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

  if [ -r "$CS_SETTINGS_APPLIED_FILE" ] && command -v settings >/dev/null 2>&1; then
    while IFS='|' read -r _cs_sf _cs_sns _cs_skv || [ -n "$_cs_sf" ]; do
      [ "$_cs_sf" = "$_cs_vf_name" ] || continue
      _cs_sk=${_cs_skv%%=*}
      _cs_sv=${_cs_skv#*=}
      if [ -z "$_cs_sns" ] || [ -z "$_cs_sk" ]; then
        continue
      fi

      # Treat Binder Failure/Exception as skipped (not ignored_by_rom)
      if ! cs_verify_settings_get "$_cs_sns" "$_cs_sk"; then
        cs_log "Verifier: settings --user 0 get ${_cs_sns}/${_cs_sk} returned Binder error; skipping setting check."
        continue
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

  : > "$CS_OVERRIDDEN_PROPS_FILE"
  CS_VERIFY_TMP="$CS_VERIFY_FILE.tmp.$$"
  : > "$CS_VERIFY_TMP"

  cs_verify_xml_mount
  cs_verify_rro_overlays

  cs_verify_feature "FEAT_BLUR" "$CFG_FEAT_BLUR" "$EFF_FEAT_BLUR"
  _cs_v_blur=$CS_VF_RESULT
  cs_verify_feature "FEAT_ANIMATIONS" "$CFG_FEAT_ANIMATIONS" "$EFF_FEAT_ANIMATIONS"
  _cs_v_anim=$CS_VF_RESULT
  cs_verify_feature "FEAT_MULTITASK" "$CFG_FEAT_MULTITASK" "$EFF_FEAT_MULTITASK"
  _cs_v_multi=$CS_VF_RESULT
  cs_verify_feature "FEAT_DISPLAY_HZ" "$CFG_FEAT_DISPLAY_HZ" "$EFF_FEAT_DISPLAY_HZ"
  _cs_v_hz=$CS_VF_RESULT
  cs_verify_feature "FEAT_HYPERAI" "$CFG_FEAT_HYPERAI" "$EFF_FEAT_HYPERAI"
  _cs_v_ai=$CS_VF_RESULT
  cs_verify_feature "FEAT_AOD_UNLOCK" "$CFG_FEAT_AOD_UNLOCK" "$EFF_FEAT_AOD_UNLOCK"
  _cs_v_aod=$CS_VF_RESULT

  cs_verify_set "VERIFY_FEAT_BLUR" "$_cs_v_blur"
  cs_verify_set "VERIFY_FEAT_ANIMATIONS" "$_cs_v_anim"
  cs_verify_set "VERIFY_FEAT_XML_PATCHER" "$CS_V_XML_FEAT"
  cs_verify_set "VERIFY_FEAT_RRO_OVERLAYS" "$CS_V_RRO_FEAT"
  cs_verify_set "VERIFY_FEAT_MULTITASK" "$_cs_v_multi"
  cs_verify_set "VERIFY_FEAT_DISPLAY_HZ" "$_cs_v_hz"
  cs_verify_set "VERIFY_FEAT_HYPERAI" "$_cs_v_ai"
  cs_verify_set "VERIFY_FEAT_AOD_UNLOCK" "$_cs_v_aod"
  cs_verify_set "VERIFY_XML_MOUNT" "$CS_V_XML_MOUNT"
  cs_verify_set "VERIFY_RRO_ACTIVE" "$CS_V_RRO_ACTIVE"
  cs_verify_set "VERIFY_RRO_TOTAL" "$CS_V_RRO_TOTAL"
  cs_verify_set "VERIFY_PROPS_TOTAL" "$CS_V_PROPS_TOTAL"
  cs_verify_set "VERIFY_PROPS_MATCHED" "$CS_V_PROPS_MATCHED"
  cs_verify_set "VERIFY_PROPS_OVERRIDDEN" "$CS_V_PROPS_OVERRIDDEN"

  mv -f "$CS_VERIFY_TMP" "$CS_VERIFY_FILE"
  cs_log "Verifier: props ${CS_V_PROPS_MATCHED}/${CS_V_PROPS_TOTAL} matched (${CS_V_PROPS_OVERRIDDEN} overridden), xml_mount=${CS_V_XML_MOUNT}, rro=${CS_V_RRO_ACTIVE}/${CS_V_RRO_TOTAL}."
  return 0
}
