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

if cs_watchdog_monitor_systemui; then
  cs_detect_rom || true
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_features

  cs_settings_sync_all || true
  cs_verifier_run || true
fi

exit 0
