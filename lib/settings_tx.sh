#!/system/bin/sh
# CoreSurface - Transactional Android `settings` Override & Clean Rollback
# Pure POSIX sh. Uses `settings --user 0` with UID 2000 (shell) fallback for
# Android 16 (SDK 36) KernelSU Binder rules, plus legacy fallback for older Android.

CS_SETTINGS_BACKUP_FILE="$CS_STATE_DIR/settings_backup.prop"
CS_SETTINGS_APPLIED_FILE="$CS_STATE_DIR/settings_applied.list"

cs_settings_available() {
  command -v settings >/dev/null 2>&1
}

cs_settings_is_error_output() {
  case "$1" in
    *Failure*|*Exception*|*Error*|*Binder*|*Permission*) return 0 ;;
    *) return 1 ;;
  esac
}

cs_sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Read a setting: try `--user 0`, then `su 2000 -c` (Android 16 Binder), then bare `settings`.
# Sets: CS_SETTINGS_READ_VAL, returns 0 on success, 1 on Binder/service error.
cs_settings_get() {
  _cs_sg_ns=$1
  _cs_sg_key=$2
  CS_SETTINGS_READ_VAL=""

  _cs_sg_out=$(settings --user 0 get "$_cs_sg_ns" "$_cs_sg_key" 2>&1)
  _cs_sg_rc=$?
  _cs_sg_line=$(printf '%s\n' "$_cs_sg_out" | head -n 1 | tr -d '\r')
  if [ "$_cs_sg_rc" -eq 0 ] && [ -n "$_cs_sg_line" ] && ! cs_settings_is_error_output "$_cs_sg_line"; then
    CS_SETTINGS_READ_VAL="$_cs_sg_line"
    return 0
  fi

  if command -v su >/dev/null 2>&1; then
    _cs_q_ns=$(cs_sh_quote "$_cs_sg_ns")
    _cs_q_key=$(cs_sh_quote "$_cs_sg_key")
    _cs_sg_out=$(su 2000 -c "settings --user 0 get ${_cs_q_ns} ${_cs_q_key}" 2>&1)
    _cs_sg_rc=$?
    _cs_sg_line=$(printf '%s\n' "$_cs_sg_out" | head -n 1 | tr -d '\r')
    if [ "$_cs_sg_rc" -eq 0 ] && [ -n "$_cs_sg_line" ] && ! cs_settings_is_error_output "$_cs_sg_line"; then
      CS_SETTINGS_READ_VAL="$_cs_sg_line"
      return 0
    fi
  fi

  _cs_sg_out=$(settings get "$_cs_sg_ns" "$_cs_sg_key" 2>&1)
  _cs_sg_rc=$?
  _cs_sg_line=$(printf '%s\n' "$_cs_sg_out" | head -n 1 | tr -d '\r')
  if [ "$_cs_sg_rc" -eq 0 ] && [ -n "$_cs_sg_line" ] && ! cs_settings_is_error_output "$_cs_sg_line"; then
    CS_SETTINGS_READ_VAL="$_cs_sg_line"
    return 0
  fi

  return 1
}

cs_settings_put() {
  _cs_sp_ns=$1
  _cs_sp_key=$2
  _cs_sp_val=$3

  _cs_sp_out=$(settings --user 0 put "$_cs_sp_ns" "$_cs_sp_key" "$_cs_sp_val" 2>&1)
  _cs_sp_rc=$?
  if [ "$_cs_sp_rc" -eq 0 ] && ! cs_settings_is_error_output "$_cs_sp_out"; then
    return 0
  fi

  if command -v su >/dev/null 2>&1; then
    _cs_q_ns=$(cs_sh_quote "$_cs_sp_ns")
    _cs_q_key=$(cs_sh_quote "$_cs_sp_key")
    _cs_q_val=$(cs_sh_quote "$_cs_sp_val")
    _cs_sp_out=$(su 2000 -c "settings --user 0 put ${_cs_q_ns} ${_cs_q_key} ${_cs_q_val}" 2>&1)
    _cs_sp_rc=$?
    if [ "$_cs_sp_rc" -eq 0 ] && ! cs_settings_is_error_output "$_cs_sp_out"; then
      return 0
    fi
  fi

  _cs_sp_out=$(settings put "$_cs_sp_ns" "$_cs_sp_key" "$_cs_sp_val" 2>&1)
  _cs_sp_rc=$?
  if [ "$_cs_sp_rc" -eq 0 ] && ! cs_settings_is_error_output "$_cs_sp_out"; then
    return 0
  fi

  return 1
}

cs_settings_delete() {
  _cs_sd_ns=$1
  _cs_sd_key=$2

  _cs_sd_out=$(settings --user 0 delete "$_cs_sd_ns" "$_cs_sd_key" 2>&1)
  _cs_sd_rc=$?
  if [ "$_cs_sd_rc" -eq 0 ] && ! cs_settings_is_error_output "$_cs_sd_out"; then
    return 0
  fi

  if command -v su >/dev/null 2>&1; then
    _cs_q_ns=$(cs_sh_quote "$_cs_sd_ns")
    _cs_q_key=$(cs_sh_quote "$_cs_sd_key")
    _cs_sd_out=$(su 2000 -c "settings --user 0 delete ${_cs_q_ns} ${_cs_q_key}" 2>&1)
    _cs_sd_rc=$?
    if [ "$_cs_sd_rc" -eq 0 ] && ! cs_settings_is_error_output "$_cs_sd_out"; then
      return 0
    fi
  fi

  _cs_sd_out=$(settings delete "$_cs_sd_ns" "$_cs_sd_key" 2>&1)
  _cs_sd_rc=$?
  if [ "$_cs_sd_rc" -eq 0 ] && ! cs_settings_is_error_output "$_cs_sd_out"; then
    return 0
  fi

  return 1
}

cs_settings_backup_has() {
  _cs_sbh_id="${1}|${2}"
  [ -r "$CS_SETTINGS_BACKUP_FILE" ] || return 1
  awk -F '=' -v id="$_cs_sbh_id" '$1 == id { found=1; exit } END { exit(found ? 0 : 1) }' "$CS_SETTINGS_BACKUP_FILE"
}

cs_settings_backup_get() {
  _cs_sbg_id="${1}|${2}"
  [ -r "$CS_SETTINGS_BACKUP_FILE" ] || return 1
  awk -F '=' -v id="$_cs_sbg_id" '$1 == id { sub(/^[^=]*=/, ""); print; exit }' "$CS_SETTINGS_BACKUP_FILE"
}

cs_settings_backup_remove() {
  _cs_sbr_id="${1}|${2}"
  [ -r "$CS_SETTINGS_BACKUP_FILE" ] || return 0
  _cs_sbr_tmp="$CS_SETTINGS_BACKUP_FILE.tmp.$$"
  awk -F '=' -v id="$_cs_sbr_id" '$1 != id { print $0 }' "$CS_SETTINGS_BACKUP_FILE" > "$_cs_sbr_tmp"
  mv -f "$_cs_sbr_tmp" "$CS_SETTINGS_BACKUP_FILE"
}

cs_settings_backup_once() {
  _cs_sbo_ns=$1
  _cs_sbo_key=$2

  cs_watchdog_init_dir || return 1
  if cs_settings_backup_has "$_cs_sbo_ns" "$_cs_sbo_key"; then
    return 0
  fi

  if ! cs_settings_get "$_cs_sbo_ns" "$_cs_sbo_key"; then
    cs_log "WARN: settings get ${_cs_sbo_ns}/${_cs_sbo_key} failed (Binder error); skipping backup/override."
    return 1
  fi

  _cs_orig=$CS_SETTINGS_READ_VAL
  if [ -z "$_cs_orig" ] || [ "$_cs_orig" = "null" ]; then
    _cs_orig="null"
  fi

  printf '%s|%s=%s\n' "$_cs_sbo_ns" "$_cs_sbo_key" "$_cs_orig" >> "$CS_SETTINGS_BACKUP_FILE"
}

cs_settings_apply_key() {
  _cs_sak_feat=$1
  _cs_sak_ns=$2
  _cs_sak_key=$3
  _cs_sak_val=$4

  cs_settings_available || return 0
  cs_settings_backup_once "$_cs_sak_ns" "$_cs_sak_key" || return 1

  if cs_settings_put "$_cs_sak_ns" "$_cs_sak_key" "$_cs_sak_val"; then
    printf '%s|%s|%s=%s\n' "$_cs_sak_feat" "$_cs_sak_ns" "$_cs_sak_key" "$_cs_sak_val" >> "$CS_SETTINGS_APPLIED_FILE"
    return 0
  fi

  cs_log "WARN: settings put ${_cs_sak_ns} ${_cs_sak_key} ${_cs_sak_val} failed."
  return 1
}

cs_settings_rollback_key() {
  _cs_srk_ns=$1
  _cs_srk_key=$2

  cs_settings_available || return 0
  cs_settings_backup_has "$_cs_srk_ns" "$_cs_srk_key" || return 0

  _cs_orig=$(cs_settings_backup_get "$_cs_srk_ns" "$_cs_srk_key")
  if [ -z "$_cs_orig" ] || [ "$_cs_orig" = "null" ]; then
    cs_settings_delete "$_cs_srk_ns" "$_cs_srk_key" || true
    cs_log "Settings rollback: deleted ${_cs_srk_ns}/${_cs_srk_key} (original was null)."
  else
    cs_settings_put "$_cs_srk_ns" "$_cs_srk_key" "$_cs_orig" || true
    cs_log "Settings rollback: restored ${_cs_srk_ns}/${_cs_srk_key}=${_cs_orig}."
  fi

  cs_settings_backup_remove "$_cs_srk_ns" "$_cs_srk_key"
  return 0
}

cs_settings_build_engine_ipc() {
  printf 'motion=%s;native=%s;guard=%s;thermallod=%s;aod=%s' \
    "${EFF_FEAT_MOTION_PROFILE:-off}" \
    "${EFF_FEAT_NATIVE_TIER:-0}" \
    "${EFF_FEAT_SURGICAL_GUARD:-0}" \
    "${EFF_FEAT_THERMAL_LOD:-1}" \
    "${EFF_FEAT_AOD_UNLOCK:-1}"
}

cs_settings_sync_engine_ipc() {
  cs_watchdog_init_dir || return 0
  cs_settings_available || return 0
  _cs_ipc_val=$(cs_settings_build_engine_ipc)
  cs_settings_apply_key "FEAT_MOTION_PROFILE" "global" "coresurface_engine_v1" "$_cs_ipc_val" || true
}

# One-time cleanup on HyperOS 3+ if an earlier preview left secure/background_blur_enable=1
# stuck in Settings DB causing bloated Toasts and black Recent Apps.
cs_settings_clear_hos3_stuck_blur() {
  [ "${CS_HYPEROS_MAJOR:-0}" -ge 3 ] || return 0
  _cs_cb_marker="$CS_STATE_DIR/.cleared_hos3_stuck_blur_v3"
  [ -f "$_cs_cb_marker" ] && return 0

  if cs_settings_get "secure" "background_blur_enable"; then
    if [ "$CS_SETTINGS_READ_VAL" = "1" ]; then
      cs_settings_put "secure" "background_blur_enable" "0" || true
      cs_log "Cleanup v3: reset stuck HyperOS 3 secure/background_blur_enable=0 to clear Toast/Recents regression."
    fi
  fi
  : > "$_cs_cb_marker" 2>/dev/null || true
}

cs_settings_sync_all() {
  cs_watchdog_init_dir || return 0
  : > "$CS_SETTINGS_APPLIED_FILE"

  if ! cs_settings_available; then
    cs_log "Settings TX: 'settings' binary unavailable; skipping."
    return 0
  fi

  # Clear any stuck HyperOS 3 Advanced Textures flag once on upgrade
  cs_settings_clear_hos3_stuck_blur || true

  # Push Live Engine IPC config (instant hot-reload in SystemUI / MiuiHome / MiuiAod)
  cs_settings_sync_engine_ipc || true

  if [ "$EFF_FEAT_ANIMATIONS" = "1" ]; then
    case "${CS_EFF_TIER:-low}" in
      flagship)     _cs_dll_c=3; _cs_dll_g=3 ;;
      balanced_pro) _cs_dll_c=2; _cs_dll_g=3 ;;
      *)            _cs_dll_c=2; _cs_dll_g=2 ;;
    esac
    if command -v cs_resolve_never_downgrade_level_list >/dev/null 2>&1; then
      _cs_dll_val=$(cs_resolve_never_downgrade_level_list "$_cs_dll_c" "$_cs_dll_g")
    else
      _cs_dll_val="v:1,c:${_cs_dll_c},g:${_cs_dll_g}"
    fi
    cs_settings_apply_key "FEAT_ANIMATIONS" "system" "deviceLevelList" "$_cs_dll_val" || true
  else
    cs_settings_rollback_key "system" "deviceLevelList" || true
  fi

  if [ "$EFF_FEAT_BLUR" = "1" ]; then
    cs_settings_apply_key "FEAT_BLUR" "global" "disable_window_blurs" "0" || true
  else
    cs_settings_rollback_key "global" "disable_window_blurs" || true
  fi

  if [ "$EFF_FEAT_MULTITASK" = "1" ]; then
    cs_settings_apply_key "FEAT_MULTITASK" "global" "enable_freeform_support" "1" || true
    cs_settings_apply_key "FEAT_MULTITASK" "global" "force_resizable_activities" "1" || true
  else
    cs_settings_rollback_key "global" "enable_freeform_support" || true
    cs_settings_rollback_key "global" "force_resizable_activities" || true
  fi

  if [ "$EFF_FEAT_DISPLAY_HZ" = "1" ]; then
    cs_settings_apply_key "FEAT_DISPLAY_HZ" "system" "miui_refresh_rate_adaptive" "1" || true
  else
    cs_settings_rollback_key "system" "miui_refresh_rate_adaptive" || true
  fi

  if [ "$EFF_FEAT_AOD_UNLOCK" = "1" ]; then
    cs_settings_apply_key "FEAT_AOD_UNLOCK" "secure" "doze_always_on" "1" || true
    cs_settings_apply_key "FEAT_AOD_UNLOCK" "secure" "aod_mode_time" "0" || true
  else
    cs_settings_rollback_key "secure" "doze_always_on" || true
    cs_settings_rollback_key "secure" "aod_mode_time" || true
  fi

  return 0
}

cs_settings_rollback_all() {
  [ -r "$CS_SETTINGS_BACKUP_FILE" ] || return 0
  cs_settings_available || return 0

  while IFS='=' read -r _cs_id _cs_orig || [ -n "$_cs_id" ]; do
    _cs_id=$(printf '%s' "$_cs_id" | tr -d '\r')
    _cs_orig=$(printf '%s' "$_cs_orig" | tr -d '\r')
    [ -n "$_cs_id" ] || continue

    _cs_ns=${_cs_id%%|*}
    _cs_key=${_cs_id#*|}
    if [ -z "$_cs_ns" ] || [ -z "$_cs_key" ]; then
      continue
    fi

    if [ -z "$_cs_orig" ] || [ "$_cs_orig" = "null" ]; then
      cs_settings_delete "$_cs_ns" "$_cs_key" || true
    else
      cs_settings_put "$_cs_ns" "$_cs_key" "$_cs_orig" || true
    fi
  done < "$CS_SETTINGS_BACKUP_FILE"

  rm -f "$CS_SETTINGS_BACKUP_FILE" "$CS_SETTINGS_APPLIED_FILE"
  return 0
}
