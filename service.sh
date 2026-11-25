#!/system/bin/sh
# CoreSurface v1.0.0 - Late Start Service
# 1. Monitors sys.boot_completed=1 + SystemUI PID grace window + 30s stability.
# 2. Synchronizes transactional Android settings (backup-once / auto-rollback).
# 3. Runs User-Space Capability Verifier -> /data/adb/coresurface/verify.state.

MODDIR=${CORESURFACE_MODDIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}

# shellcheck source=lib/detect.sh
. "$MODDIR/lib/detect.sh"
# shellcheck source=lib/watchdog.sh
. "$MODDIR/lib/watchdog.sh"
# shellcheck source=lib/settings_tx.sh
. "$MODDIR/lib/settings_tx.sh"
# shellcheck source=lib/verifier.sh
. "$MODDIR/lib/verifier.sh"
# shellcheck source=lib/os_bug_logic.sh
. "$MODDIR/lib/os_bug_logic.sh"

CS_CONFIG_FILE="$CS_STATE_DIR/config.prop"

_cs_cur_status=$(cs_state_get "WATCHDOG_STATUS")
case "$_cs_cur_status" in
  unsupported_rom)
    exit 0
    ;;
  safe_mode_disabled)
    # Wait for boot completion before rolling back any prior settings overrides
    _cs_sb_t=0
    _cs_sb_max=${CORESURFACE_BOOT_TIMEOUT:-120}
    _cs_sb_poll=${CORESURFACE_POLL_INTERVAL:-2}
    while [ "$(getprop sys.boot_completed 2>/dev/null || true)" != "1" ]; do
      [ "$_cs_sb_t" -ge "$_cs_sb_max" ] && break
      sleep "$_cs_sb_poll"
      _cs_sb_t=$((_cs_sb_t + _cs_sb_poll))
    done
    cs_settings_rollback_all || true
    exit 0
    ;;
esac

cs_pm_try_install_once() {
  _cs_pi_apk=$1
  _cs_pi_size=$(wc -c < "$_cs_pi_apk" 2>/dev/null | tr -d ' \t\r\n')
  CS_PM_LAST_OUT=""

  if [ -n "$_cs_pi_size" ] && [ "$_cs_pi_size" -gt 0 ] 2>/dev/null; then
    CS_PM_LAST_OUT=$(pm install -r -S "$_cs_pi_size" < "$_cs_pi_apk" 2>&1 || true)
    case "$CS_PM_LAST_OUT" in
      *Success*) return 0 ;;
      *INSTALL_FAILED_UPDATE_INCOMPATIBLE*) return 2 ;;
    esac
  fi

  # SELinux-safe fallback: stage in /data/local/tmp (readable by installd & UID 2000)
  _cs_pi_tmp="/data/local/tmp/coresurface_engine_install.apk"
  if cp "$_cs_pi_apk" "$_cs_pi_tmp" 2>/dev/null; then
    chmod 0644 "$_cs_pi_tmp" 2>/dev/null || true
    CS_PM_LAST_OUT=$(pm install -r "$_cs_pi_tmp" 2>&1 || true)
    case "$CS_PM_LAST_OUT" in
      *Success*)
        rm -f "$_cs_pi_tmp" 2>/dev/null || true
        return 0
        ;;
      *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
        rm -f "$_cs_pi_tmp" 2>/dev/null || true
        return 2
        ;;
    esac
    if command -v su >/dev/null 2>&1; then
      CS_PM_LAST_OUT=$(su 2000 -c "pm install -r ${_cs_pi_tmp}" 2>&1 || true)
      case "$CS_PM_LAST_OUT" in
        *Success*)
          rm -f "$_cs_pi_tmp" 2>/dev/null || true
          return 0
          ;;
        *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
          rm -f "$_cs_pi_tmp" 2>/dev/null || true
          return 2
          ;;
      esac
    fi
    rm -f "$_cs_pi_tmp" 2>/dev/null || true
  fi

  return 1
}

cs_pm_install_apk() {
  _cs_pi_target=$1
  [ -r "$_cs_pi_target" ] || return 1
  command -v pm >/dev/null 2>&1 || return 1

  cs_pm_try_install_once "$_cs_pi_target"
  _cs_pi_rc=$?
  if [ "$_cs_pi_rc" -eq 0 ]; then
    return 0
  fi
  if [ "$_cs_pi_rc" -eq 2 ]; then
    pm uninstall org.mystivara.coresurface.engine >/dev/null 2>&1 || true
    if command -v su >/dev/null 2>&1; then
      su 2000 -c "pm uninstall org.mystivara.coresurface.engine" >/dev/null 2>&1 || true
    fi
    cs_log "Engine Installer: replaced previous signature build of CoreSurfaceEngine.apk."
    cs_pm_try_install_once "$_cs_pi_target"
    return $?
  fi

  return 1
}

cs_install_engine_if_needed() {
  _cs_apk="$CS_STATE_DIR/CoreSurfaceEngine.apk"
  [ -r "$_cs_apk" ] || _cs_apk="$MODDIR/engine/CoreSurfaceEngine.apk"
  [ -r "$_cs_apk" ] || return 0
  command -v pm >/dev/null 2>&1 || return 0

  _cs_stamp="$CS_STATE_DIR/.engine_installed.sig"
  _cs_cur_sig=$(cksum "$_cs_apk" 2>/dev/null | awk '{print $1 "-" $2}' || true)
  _cs_prev_sig=""
  [ -r "$_cs_stamp" ] && _cs_prev_sig=$(cat "$_cs_stamp" 2>/dev/null || true)

  _cs_pm_check=$(pm path org.mystivara.coresurface.engine 2>&1 || true)
  if [ -z "$_cs_pm_check" ] && command -v su >/dev/null 2>&1; then
    _cs_pm_check=$(su 2000 -c "pm path org.mystivara.coresurface.engine" 2>&1 || true)
  fi
  if [ -n "$_cs_cur_sig" ] && [ "$_cs_cur_sig" = "$_cs_prev_sig" ]; then
    case "$_cs_pm_check" in
      package:*) return 0 ;;
    esac
  fi

  if cs_pm_install_apk "$_cs_apk"; then
    printf '%s\n' "$_cs_cur_sig" > "$_cs_stamp" 2>/dev/null || true
    cs_log "Engine Installer: installed/updated CoreSurfaceEngine.apk (enable in LSPosed)."
  else
    cs_log "Engine Installer: automatic pm install skipped (install manually from ${_cs_apk})."
  fi
  return 0
}

if cs_watchdog_monitor_systemui; then
  cs_detect_rom || true
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_features

  cs_install_engine_if_needed || true
  cs_settings_sync_all || true
  cs_os_bug_scan "late" "$MODDIR" || true
  cs_verifier_run || true
fi

exit 0
