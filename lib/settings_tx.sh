#!/system/bin/sh
# CoreSurface - Transactional Android `settings` Override & Clean Rollback
# Pure POSIX sh. Backs up original values once (idempotent) and restores cleanly.

CS_SETTINGS_BACKUP_FILE="$CS_STATE_DIR/settings_backup.prop"
CS_SETTINGS_APPLIED_FILE="$CS_STATE_DIR/settings_applied.list"

cs_settings_available() {
  command -v settings >/dev/null 2>&1
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

# Idempotent backup: record original value from `settings get` only once.
# Never overwrites an existing backup entry.
cs_settings_backup_once() {
  _cs_sbo_ns=$1
  _cs_sbo_key=$2

  cs_watchdog_init_dir || return 1
  if cs_settings_backup_has "$_cs_sbo_ns" "$_cs_sbo_key"; then
    return 0
  fi

  _cs_orig=$(settings get "$_cs_sbo_ns" "$_cs_sbo_key" 2>/dev/null | head -n 1 | tr -d '\r' || true)
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

  if settings put "$_cs_sak_ns" "$_cs_sak_key" "$_cs_sak_val" >/dev/null 2>&1; then
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
    settings delete "$_cs_srk_ns" "$_cs_srk_key" >/dev/null 2>&1 || true
    cs_log "Settings rollback: deleted ${_cs_srk_ns}/${_cs_srk_key} (original was null)."
  else
    settings put "$_cs_srk_ns" "$_cs_srk_key" "$_cs_orig" >/dev/null 2>&1 || true
    cs_log "Settings rollback: restored ${_cs_srk_ns}/${_cs_srk_key}=${_cs_orig}."
  fi

  cs_settings_backup_remove "$_cs_srk_ns" "$_cs_srk_key"
  return 0
}

# Synchronize settings according to currently resolved EFF_FEAT_* flags:
# - Enabled features: backup once & apply
# - Disabled/skipped features: automatically roll back to original value
cs_settings_sync_all() {
  cs_watchdog_init_dir || return 0
  : > "$CS_SETTINGS_APPLIED_FILE"

  if ! cs_settings_available; then
    cs_log "Settings TX: 'settings' binary unavailable; skipping."
    return 0
  fi

  # FEAT_BLUR: ensure WindowManager blur is not globally suppressed
  if [ "$EFF_FEAT_BLUR" = "1" ]; then
    cs_settings_apply_key "FEAT_BLUR" "global" "disable_window_blurs" "0" || true
  else
    cs_settings_rollback_key "global" "disable_window_blurs" || true
  fi

  # FEAT_MULTITASK: Android freeform & resizable window flags
  if [ "$EFF_FEAT_MULTITASK" = "1" ]; then
    cs_settings_apply_key "FEAT_MULTITASK" "global" "enable_freeform_support" "1" || true
    cs_settings_apply_key "FEAT_MULTITASK" "global" "force_resizable_activities" "1" || true
  else
    cs_settings_rollback_key "global" "enable_freeform_support" || true
    cs_settings_rollback_key "global" "force_resizable_activities" || true
  fi

  # FEAT_DISPLAY_HZ: adaptive high refresh rate UI flag
  if [ "$EFF_FEAT_DISPLAY_HZ" = "1" ]; then
    cs_settings_apply_key "FEAT_DISPLAY_HZ" "system" "miui_refresh_rate_adaptive" "1" || true
  else
    cs_settings_rollback_key "system" "miui_refresh_rate_adaptive" || true
  fi

  # FEAT_AOD_UNLOCK: Always-On Display secure toggle
  if [ "$EFF_FEAT_AOD_UNLOCK" = "1" ]; then
    cs_settings_apply_key "FEAT_AOD_UNLOCK" "secure" "doze_always_on" "1" || true
  else
    cs_settings_rollback_key "secure" "doze_always_on" || true
  fi

  return 0
}

# Roll back every entry recorded in settings_backup.prop (used on uninstall or safe-mode).
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
      settings delete "$_cs_ns" "$_cs_key" >/dev/null 2>&1 || true
    else
      settings put "$_cs_ns" "$_cs_key" "$_cs_orig" >/dev/null 2>&1 || true
    fi
  done < "$CS_SETTINGS_BACKUP_FILE"

  rm -f "$CS_SETTINGS_BACKUP_FILE" "$CS_SETTINGS_APPLIED_FILE"
  return 0
}
