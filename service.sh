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
  if [ -n "$_cs_cur_sig" ] && [ "$_cs_cur_sig" = "$_cs_prev_sig" ]; then
    case "$_cs_pm_check" in
      package:*) return 0 ;;
    esac
  fi

  _cs_inst_out=$(pm install -r "$_cs_apk" 2>&1 || true)
  case "$_cs_inst_out" in
    *Success*)
      printf '%s\n' "$_cs_cur_sig" > "$_cs_stamp" 2>/dev/null || true
      cs_log "Engine Installer: installed/updated CoreSurfaceEngine.apk (enable in LSPosed)."
      return 0
      ;;
  esac

  if command -v su >/dev/null 2>&1; then
    _cs_inst_out=$(su 2000 -c "pm install -r ${_cs_apk}" 2>&1 || true)
    case "$_cs_inst_out" in
      *Success*)
        printf '%s\n' "$_cs_cur_sig" > "$_cs_stamp" 2>/dev/null || true
        cs_log "Engine Installer: installed/updated CoreSurfaceEngine.apk via UID 2000."
        return 0
        ;;
    esac
  fi

  cs_log "Engine Installer: automatic pm install skipped (install manually from ${_cs_apk})."
  return 0
}

if cs_watchdog_monitor_systemui; then
  cs_detect_rom || true
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_features

  cs_install_engine_if_needed || true
  cs_settings_sync_all || true
  cs_verifier_run || true
fi

exit 0
