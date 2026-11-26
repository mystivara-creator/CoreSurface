#!/system/bin/sh
# CoreSurface - Late Start Service (100% Standalone, Zero LSPosed)
# 1. Monitors sys.boot_completed=1 + SystemUI PID grace window + 30s stability.
# 2. Removes any legacy org.mystivara.coresurface.engine APK left over from older versions.
# 3. Re-asserts flagship computility props, activates staged RROs, and syncs transactional settings.
# 4. Runs OS Bug Logic late scan + User-Space Capability Verifier -> verify.state.

MODDIR=${CORESURFACE_MODDIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}

# shellcheck source=lib/detect.sh
. "$MODDIR/lib/detect.sh"
# shellcheck source=lib/watchdog.sh
. "$MODDIR/lib/watchdog.sh"
# shellcheck source=lib/props.sh
. "$MODDIR/lib/props.sh"
# shellcheck source=lib/rro.sh
. "$MODDIR/lib/rro.sh"
# shellcheck source=lib/xml_patcher.sh
. "$MODDIR/lib/xml_patcher.sh"
# shellcheck source=lib/settings_tx.sh
. "$MODDIR/lib/settings_tx.sh"
# shellcheck source=lib/verifier.sh
. "$MODDIR/lib/verifier.sh"
# shellcheck source=lib/os_bug_logic.sh
. "$MODDIR/lib/os_bug_logic.sh"

CS_CONFIG_FILE="$CS_STATE_DIR/config.prop"

cs_cleanup_legacy_engine_once() {
  _cs_leg_marker="$CS_STATE_DIR/.removed_legacy_engine_v13"
  [ -f "$_cs_leg_marker" ] && return 0
  command -v pm >/dev/null 2>&1 || return 0

  _cs_leg_pkg="org.mystivara.coresurface.engine"
  _cs_leg_out=$(pm path "$_cs_leg_pkg" 2>&1 || true)
  case "$_cs_leg_out" in
    package:*)
      pm uninstall "$_cs_leg_pkg" >/dev/null 2>&1 || true
      if command -v su >/dev/null 2>&1; then
        su 2000 -c "pm uninstall '${_cs_leg_pkg}'" >/dev/null 2>&1 || true
        su --context u:r:shell:s0 2000 -c "pm uninstall '${_cs_leg_pkg}'" >/dev/null 2>&1 || true
      fi
      cs_log "Upgrade cleanup: removed legacy CoreSurfaceEngine.apk (CoreSurface is now 100% standalone)."
      ;;
  esac
  : > "$_cs_leg_marker" 2>/dev/null || true
}

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

if cs_watchdog_monitor_systemui; then
  cs_detect_rom || true
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_features

  cs_cleanup_legacy_engine_once || true
  [ -s "$CS_HW_FPS_FILE" ] || cs_probe_hw_fps || true
  cs_reassert_computility_props || true
  cs_rro_enable_staged || true
  cs_settings_sync_all || true
  cs_os_bug_scan "late" "$MODDIR" || true
  cs_verifier_run || true
fi

exit 0
