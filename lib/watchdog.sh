#!/system/bin/sh
# CoreSurface - Layer 3: Bootloop & SystemUI Health Watchdog
# Pure POSIX sh. Fail-closed on >= 2 consecutive failed boots.

CS_STATE_DIR=${CORESURFACE_STATE_DIR:-/data/adb/coresurface}
CS_STRIKE_FILE="$CS_STATE_DIR/boot_strikes"
CS_STATE_FILE="$CS_STATE_DIR/state.prop"
CS_LOG_FILE="$CS_STATE_DIR/coresurface.log"
CS_PROPS_AUDIT_FILE="$CS_STATE_DIR/applied_props.list"

cs_watchdog_init_dir() {
  mkdir -p "$CS_STATE_DIR" 2>/dev/null || return 1
}

cs_log() {
  cs_watchdog_init_dir || return 0
  _cs_ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'boot')
  printf '[%s] %s\n' "$_cs_ts" "$1" >> "$CS_LOG_FILE" 2>/dev/null || true
}

cs_log_trim() {
  [ -r "$CS_LOG_FILE" ] || return 0
  _cs_lsz=$(wc -c < "$CS_LOG_FILE" 2>/dev/null | tr -d ' \t\r\n')
  if [ -n "$_cs_lsz" ] && [ "$_cs_lsz" -gt 65536 ] 2>/dev/null; then
    _cs_ltmp="${CS_LOG_FILE}.tmp.$$"
    if tail -n 200 "$CS_LOG_FILE" > "$_cs_ltmp" 2>/dev/null; then
      mv -f "$_cs_ltmp" "$CS_LOG_FILE" 2>/dev/null || rm -f "$_cs_ltmp" 2>/dev/null || true
    else
      rm -f "$_cs_ltmp" 2>/dev/null || true
    fi
  fi
}

cs_atomic_write() {
  _cs_aw_target=$1
  _cs_aw_content=$2
  _cs_aw_tmp="${_cs_aw_target}.tmp.$$"
  printf '%s\n' "$_cs_aw_content" > "$_cs_aw_tmp" && mv -f "$_cs_aw_tmp" "$_cs_aw_target"
}

cs_read_strikes() {
  _cs_val="0"
  if [ -r "$CS_STRIKE_FILE" ]; then
    _cs_raw=$(head -n 1 "$CS_STRIKE_FILE" 2>/dev/null | tr -d ' \t\r\n')
    case "$_cs_raw" in
      ''|*[!0-9]*) _cs_val="0" ;;
      *) _cs_val="$_cs_raw" ;;
    esac
  fi
  printf '%s\n' "$_cs_val"
}

cs_write_strikes() {
  cs_watchdog_init_dir || return 1
  cs_atomic_write "$CS_STRIKE_FILE" "$1"
}

cs_state_set() {
  _cs_sk=$1
  _cs_sv=$2
  cs_watchdog_init_dir || return 1
  _cs_tmp="$CS_STATE_FILE.tmp.$$"
  if [ -r "$CS_STATE_FILE" ]; then
    awk -F '=' -v k="$_cs_sk" '$1 != k { print $0 }' "$CS_STATE_FILE" > "$_cs_tmp" 2>/dev/null || : > "$_cs_tmp"
  else
    : > "$_cs_tmp"
  fi
  printf '%s=%s\n' "$_cs_sk" "$_cs_sv" >> "$_cs_tmp"
  mv -f "$_cs_tmp" "$CS_STATE_FILE"
}

cs_state_get() {
  _cs_gk=$1
  if [ -r "$CS_STATE_FILE" ]; then
    awk -F '=' -v k="$_cs_gk" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$CS_STATE_FILE" 2>/dev/null || true
  fi
}

# Preflight strike check in post-fs-data.sh BEFORE applying any resetprop.
# Returns:
#   0 -> safe to proceed (strike incremented)
#   2 -> safe-mode triggered (module disabled, caller must exit 0 immediately)
cs_watchdog_preflight() {
  _cs_moddir=$1
  cs_watchdog_init_dir || return 1

  _cs_strikes=$(cs_read_strikes)
  if [ "$_cs_strikes" -ge 2 ]; then
    : > "$_cs_moddir/disable"
    cs_write_strikes "0"
    : > "$CS_PROPS_AUDIT_FILE"
    cs_state_set "WATCHDOG_STATUS" "safe_mode_disabled"
    cs_state_set "WATCHDOG_REASON" "boot_strikes_reached_2_auto_disabled"
    cs_log "SAFE-MODE: boot_strikes=${_cs_strikes} (>=2). Created ${_cs_moddir}/disable, reset strikes=0, exiting fail-closed."
    return 2
  fi

  _cs_next=$((_cs_strikes + 1))
  cs_write_strikes "$_cs_next"
  cs_state_set "WATCHDOG_STATUS" "booting"
  cs_state_set "WATCHDOG_REASON" "preflight_strike_${_cs_next}"
  cs_log "Watchdog preflight: boot_strikes incremented ${_cs_strikes} -> ${_cs_next}."
  return 0
}

# Monitor boot completion and com.android.systemui PID stability in service.sh.
# Environment overrides for host unit tests:
#   CORESURFACE_BOOT_TIMEOUT   (default 180s)
#   CORESURFACE_SYSUI_WAIT     (default 30s grace window for SystemUI to appear)
#   CORESURFACE_HEALTH_SECONDS (default 30s continuous stability window)
#   CORESURFACE_POLL_INTERVAL  (default 2s)
cs_watchdog_monitor_systemui() {
  _cs_boot_timeout=${CORESURFACE_BOOT_TIMEOUT:-180}
  _cs_sysui_wait=${CORESURFACE_SYSUI_WAIT:-30}
  _cs_health_secs=${CORESURFACE_HEALTH_SECONDS:-30}
  _cs_poll=${CORESURFACE_POLL_INTERVAL:-2}

  # 1. Wait for sys.boot_completed=1
  _cs_elapsed=0
  while [ "$(getprop sys.boot_completed 2>/dev/null || true)" != "1" ]; do
    if [ "$_cs_elapsed" -ge "$_cs_boot_timeout" ]; then
      cs_state_set "WATCHDOG_STATUS" "degraded"
      cs_state_set "WATCHDOG_REASON" "boot_completed_timeout"
      cs_log "Watchdog: timed out waiting for sys.boot_completed=1 (${_cs_boot_timeout}s)."
      return 1
    fi
    sleep "$_cs_poll"
    _cs_elapsed=$((_cs_elapsed + _cs_poll))
  done

  # 2. Grace window: wait for com.android.systemui PID to appear
  _cs_wait_elapsed=0
  _cs_initial_pid=""
  while [ -z "$_cs_initial_pid" ]; do
    _cs_initial_pid=$(pidof com.android.systemui 2>/dev/null | awk '{print $1}' || true)
    if [ -n "$_cs_initial_pid" ]; then
      break
    fi
    if [ "$_cs_wait_elapsed" -ge "$_cs_sysui_wait" ]; then
      cs_state_set "WATCHDOG_STATUS" "degraded"
      cs_state_set "WATCHDOG_REASON" "systemui_pid_missing_after_grace_window"
      cs_log "Watchdog: com.android.systemui did not appear within ${_cs_sysui_wait}s grace window."
      return 1
    fi
    sleep "$_cs_poll"
    _cs_wait_elapsed=$((_cs_wait_elapsed + _cs_poll))
  done

  cs_log "Watchdog: com.android.systemui detected (PID=${_cs_initial_pid}); verifying ${_cs_health_secs}s stability."

  # 3. Verify SystemUI PID stays identical and alive for full health window
  _cs_stable_elapsed=0
  while [ "$_cs_stable_elapsed" -lt "$_cs_health_secs" ]; do
    sleep "$_cs_poll"
    _cs_stable_elapsed=$((_cs_stable_elapsed + _cs_poll))
    _cs_cur_pid=$(pidof com.android.systemui 2>/dev/null | awk '{print $1}' || true)
    if [ -z "$_cs_cur_pid" ] || [ "$_cs_cur_pid" != "$_cs_initial_pid" ]; then
      cs_state_set "WATCHDOG_STATUS" "degraded"
      cs_state_set "WATCHDOG_REASON" "systemui_pid_changed_or_crashed"
      cs_log "Watchdog: SystemUI unstable (initial=${_cs_initial_pid}, current=${_cs_cur_pid:-none} at ${_cs_stable_elapsed}s). Keeping boot_strikes."
      return 1
    fi
  done

  # 4. SystemUI verified healthy: clear boot_strikes
  cs_write_strikes "0"
  cs_state_set "WATCHDOG_STATUS" "healthy"
  cs_state_set "WATCHDOG_REASON" "systemui_stable_${_cs_health_secs}s"
  cs_log "Watchdog: SystemUI stable (PID=${_cs_initial_pid}) for ${_cs_health_secs}s. Reset boot_strikes=0, status=healthy."
  return 0
}
