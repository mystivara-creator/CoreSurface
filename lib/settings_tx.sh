#!/system/bin/sh
# CoreSurface - Transactional Android `settings` Override & Clean Rollback
# Pure POSIX sh. Uses `settings --user 0` with UID 2000 (shell) fallback for
# Android 16 (SDK 36) KernelSU Binder rules, plus legacy fallback for older Android.

CS_SETTINGS_BACKUP_FILE="$CS_STATE_DIR/settings_backup.prop"
CS_SETTINGS_APPLIED_FILE="$CS_STATE_DIR/settings_applied.list"
CS_SETTINGS_BINDER_CACHE="$CS_STATE_DIR/.binder_blocked_boot"
CS_SETTINGS_TRANSPORT=""
CS_SETTINGS_BINDER_FAILED=0

cs_settings_available() {
  command -v settings >/dev/null 2>&1
}

cs_settings_boot_id() {
  _cs_bid_file=${CORESURFACE_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
  if [ -r "$_cs_bid_file" ]; then
    head -n 1 "$_cs_bid_file" 2>/dev/null | tr -d ' \t\r\n'
  fi
}

cs_settings_binder_is_cached_blocked() {
  [ -r "$CS_SETTINGS_BINDER_CACHE" ] || return 1
  _cs_cb_cur=$(cs_settings_boot_id)
  [ -n "$_cs_cb_cur" ] || return 1
  _cs_cb_prev=$(head -n 1 "$CS_SETTINGS_BINDER_CACHE" 2>/dev/null | tr -d ' \t\r\n')
  [ "$_cs_cb_prev" = "$_cs_cb_cur" ]
}

cs_settings_binder_mark_blocked() {
  CS_SETTINGS_BINDER_FAILED=1
  export CS_SETTINGS_BINDER_FAILED
  _cs_mb_cur=$(cs_settings_boot_id)
  if [ -n "$_cs_mb_cur" ] && [ -d "$CS_STATE_DIR" ]; then
    printf '%s\n' "$_cs_mb_cur" > "$CS_SETTINGS_BINDER_CACHE" 2>/dev/null || true
  fi
}

cs_settings_find_busybox() {
  for _cs_bb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    if [ -x "$_cs_bb" ]; then
      printf '%s' "$_cs_bb"
      return 0
    fi
  done
  return 1
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

# Execute a settings subcommand via a specific transport.
# Args: $1=transport, $2=op (get|put|delete), $3=ns, $4=key, $5=val(optional)
cs_settings_exec_transport() {
  _cs_et_tr=$1
  _cs_et_op=$2
  _cs_et_ns=$3
  _cs_et_key=$4
  _cs_et_val=${5:-}
  CS_SETTINGS_EXEC_OUT=""

  case "$_cs_et_tr" in
    direct)
      if [ "$_cs_et_op" = "put" ]; then
        CS_SETTINGS_EXEC_OUT=$(settings --user 0 put "$_cs_et_ns" "$_cs_et_key" "$_cs_et_val" 2>&1)
      else
        CS_SETTINGS_EXEC_OUT=$(settings --user 0 "$_cs_et_op" "$_cs_et_ns" "$_cs_et_key" 2>&1)
      fi
      ;;
    cmd)
      command -v cmd >/dev/null 2>&1 || return 127
      if [ "$_cs_et_op" = "put" ]; then
        CS_SETTINGS_EXEC_OUT=$(cmd settings --user 0 put "$_cs_et_ns" "$_cs_et_key" "$_cs_et_val" 2>&1)
      else
        CS_SETTINGS_EXEC_OUT=$(cmd settings --user 0 "$_cs_et_op" "$_cs_et_ns" "$_cs_et_key" 2>&1)
      fi
      ;;
    su2000)
      command -v su >/dev/null 2>&1 || return 127
      _cs_q_ns=$(cs_sh_quote "$_cs_et_ns")
      _cs_q_key=$(cs_sh_quote "$_cs_et_key")
      if [ "$_cs_et_op" = "put" ]; then
        _cs_q_val=$(cs_sh_quote "$_cs_et_val")
        CS_SETTINGS_EXEC_OUT=$(su 2000 -c "settings --user 0 put ${_cs_q_ns} ${_cs_q_key} ${_cs_q_val}" 2>&1)
      else
        CS_SETTINGS_EXEC_OUT=$(su 2000 -c "settings --user 0 ${_cs_et_op} ${_cs_q_ns} ${_cs_q_key}" 2>&1)
      fi
      ;;
    su_shell)
      command -v su >/dev/null 2>&1 || return 127
      _cs_q_ns=$(cs_sh_quote "$_cs_et_ns")
      _cs_q_key=$(cs_sh_quote "$_cs_et_key")
      if [ "$_cs_et_op" = "put" ]; then
        _cs_q_val=$(cs_sh_quote "$_cs_et_val")
        CS_SETTINGS_EXEC_OUT=$(su --context u:r:shell:s0 2000 -c "settings --user 0 put ${_cs_q_ns} ${_cs_q_key} ${_cs_q_val}" 2>&1)
      else
        CS_SETTINGS_EXEC_OUT=$(su --context u:r:shell:s0 2000 -c "settings --user 0 ${_cs_et_op} ${_cs_q_ns} ${_cs_q_key}" 2>&1)
      fi
      ;;
    runcon_shell)
      command -v runcon >/dev/null 2>&1 || return 127
      _cs_et_bb=$(cs_settings_find_busybox) || return 127
      if [ "$_cs_et_op" = "put" ]; then
        CS_SETTINGS_EXEC_OUT=$(runcon u:r:shell:s0 "$_cs_et_bb" setuidgid 2000 settings --user 0 put "$_cs_et_ns" "$_cs_et_key" "$_cs_et_val" 2>&1)
      else
        CS_SETTINGS_EXEC_OUT=$(runcon u:r:shell:s0 "$_cs_et_bb" setuidgid 2000 settings --user 0 "$_cs_et_op" "$_cs_et_ns" "$_cs_et_key" 2>&1)
      fi
      ;;
    setuidgid)
      _cs_et_bb=$(cs_settings_find_busybox) || return 127
      if [ "$_cs_et_op" = "put" ]; then
        CS_SETTINGS_EXEC_OUT=$("$_cs_et_bb" setuidgid 2000 settings --user 0 put "$_cs_et_ns" "$_cs_et_key" "$_cs_et_val" 2>&1)
      else
        CS_SETTINGS_EXEC_OUT=$("$_cs_et_bb" setuidgid 2000 settings --user 0 "$_cs_et_op" "$_cs_et_ns" "$_cs_et_key" 2>&1)
      fi
      ;;
    legacy)
      if [ "$_cs_et_op" = "put" ]; then
        CS_SETTINGS_EXEC_OUT=$(settings put "$_cs_et_ns" "$_cs_et_key" "$_cs_et_val" 2>&1)
      else
        CS_SETTINGS_EXEC_OUT=$(settings "$_cs_et_op" "$_cs_et_ns" "$_cs_et_key" 2>&1)
      fi
      ;;
    *)
      return 127
      ;;
  esac
}

# Read a setting using cached winning transport (or probe transports once).
# Sets: CS_SETTINGS_READ_VAL, CS_SETTINGS_LAST_ERR. Returns 0 on success, 1 on Binder/service error.
cs_settings_get() {
  _cs_sg_ns=$1
  _cs_sg_key=$2
  CS_SETTINGS_READ_VAL=""
  CS_SETTINGS_LAST_ERR=""
  export CS_SETTINGS_LAST_ERR

  if [ -n "$CS_SETTINGS_TRANSPORT" ]; then
    cs_settings_exec_transport "$CS_SETTINGS_TRANSPORT" "get" "$_cs_sg_ns" "$_cs_sg_key"
    _cs_sg_rc=$?
    _cs_sg_line=$(printf '%s\n' "$CS_SETTINGS_EXEC_OUT" | head -n 1 | tr -d '\r')
    if [ "$_cs_sg_rc" -eq 0 ] && ! cs_settings_is_error_output "$CS_SETTINGS_EXEC_OUT"; then
      CS_SETTINGS_READ_VAL="${_cs_sg_line:-null}"
      return 0
    fi
    CS_SETTINGS_TRANSPORT=""
  fi

  for _cs_tr in direct cmd runcon_shell su2000 su_shell setuidgid legacy; do
    cs_settings_exec_transport "$_cs_tr" "get" "$_cs_sg_ns" "$_cs_sg_key"
    _cs_sg_rc=$?
    [ "$_cs_sg_rc" -eq 127 ] && continue
    _cs_sg_line=$(printf '%s\n' "$CS_SETTINGS_EXEC_OUT" | head -n 1 | tr -d '\r')
    if [ "$_cs_sg_rc" -eq 0 ] && ! cs_settings_is_error_output "$CS_SETTINGS_EXEC_OUT"; then
      CS_SETTINGS_TRANSPORT="$_cs_tr"
      CS_SETTINGS_READ_VAL="${_cs_sg_line:-null}"
      return 0
    fi
    [ -n "$_cs_sg_line" ] && CS_SETTINGS_LAST_ERR="$_cs_sg_line"
  done

  return 1
}

cs_settings_put() {
  _cs_sp_ns=$1
  _cs_sp_key=$2
  _cs_sp_val=$3

  if [ -n "$CS_SETTINGS_TRANSPORT" ]; then
    cs_settings_exec_transport "$CS_SETTINGS_TRANSPORT" "put" "$_cs_sp_ns" "$_cs_sp_key" "$_cs_sp_val"
    _cs_sp_rc=$?
    if [ "$_cs_sp_rc" -eq 0 ] && ! cs_settings_is_error_output "$CS_SETTINGS_EXEC_OUT"; then
      return 0
    fi
    CS_SETTINGS_TRANSPORT=""
  fi

  for _cs_tr in direct cmd su2000 su_shell setuidgid legacy; do
    cs_settings_exec_transport "$_cs_tr" "put" "$_cs_sp_ns" "$_cs_sp_key" "$_cs_sp_val"
    _cs_sp_rc=$?
    [ "$_cs_sp_rc" -eq 127 ] && continue
    if [ "$_cs_sp_rc" -eq 0 ] && ! cs_settings_is_error_output "$CS_SETTINGS_EXEC_OUT"; then
      CS_SETTINGS_TRANSPORT="$_cs_tr"
      return 0
    fi
  done

  return 1
}

cs_settings_delete() {
  _cs_sd_ns=$1
  _cs_sd_key=$2

  if [ -n "$CS_SETTINGS_TRANSPORT" ]; then
    cs_settings_exec_transport "$CS_SETTINGS_TRANSPORT" "delete" "$_cs_sd_ns" "$_cs_sd_key"
    _cs_sd_rc=$?
    if [ "$_cs_sd_rc" -eq 0 ] && ! cs_settings_is_error_output "$CS_SETTINGS_EXEC_OUT"; then
      return 0
    fi
    CS_SETTINGS_TRANSPORT=""
  fi

  for _cs_tr in direct cmd su2000 su_shell setuidgid legacy; do
    cs_settings_exec_transport "$_cs_tr" "delete" "$_cs_sd_ns" "$_cs_sd_key"
    _cs_sd_rc=$?
    [ "$_cs_sd_rc" -eq 127 ] && continue
    if [ "$_cs_sd_rc" -eq 0 ] && ! cs_settings_is_error_output "$CS_SETTINGS_EXEC_OUT"; then
      CS_SETTINGS_TRANSPORT="$_cs_tr"
      return 0
    fi
  done

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
    cs_settings_binder_mark_blocked
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
  [ "${CS_SETTINGS_BINDER_FAILED:-0}" = "1" ] && return 1
  cs_settings_backup_once "$_cs_sak_ns" "$_cs_sak_key" || return 1

  if cs_settings_put "$_cs_sak_ns" "$_cs_sak_key" "$_cs_sak_val"; then
    printf '%s|%s|%s=%s\n' "$_cs_sak_feat" "$_cs_sak_ns" "$_cs_sak_key" "$_cs_sak_val" >> "$CS_SETTINGS_APPLIED_FILE"
    return 0
  fi

  cs_settings_binder_mark_blocked
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
    : > "$_cs_cb_marker" 2>/dev/null || true
  else
    cs_settings_binder_mark_blocked
  fi
}

cs_settings_sync_all() {
  cs_watchdog_init_dir || return 0
  : > "$CS_SETTINGS_APPLIED_FILE"
  CS_SETTINGS_BINDER_FAILED=0
  export CS_SETTINGS_BINDER_FAILED

  if ! cs_settings_available; then
    cs_log "Settings TX: 'settings' binary unavailable; skipping."
    return 0
  fi

  if cs_settings_binder_is_cached_blocked; then
    CS_SETTINGS_BINDER_FAILED=1
    export CS_SETTINGS_BINDER_FAILED
    return 0
  fi

  # Clear any stuck HyperOS 3 Advanced Textures flag once on upgrade
  cs_settings_clear_hos3_stuck_blur || true
  if [ "$CS_SETTINGS_BINDER_FAILED" = "1" ]; then
    cs_log "Settings TX: Android 15/16 root Binder restricted; skipping settings writes cleanly."
    return 0
  fi

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

  if [ "${CS_SETTINGS_BINDER_FAILED:-0}" = "1" ]; then
    cs_log "Settings TX: Android 15/16 root Binder restricted; skipping settings writes cleanly."
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
