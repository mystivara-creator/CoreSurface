#!/system/bin/sh
# CoreSurface v1.0.0 - Clean Uninstall Script
# Rolls back all transactional Android `settings` overrides, purges any legacy
# leaked persist.* keys, and removes the state directory cleanly.

MODDIR=${CORESURFACE_MODDIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}
CS_STATE_DIR=${CORESURFACE_STATE_DIR:-/data/adb/coresurface}

if [ -r "$MODDIR/lib/watchdog.sh" ]; then
  # shellcheck source=lib/watchdog.sh
  . "$MODDIR/lib/watchdog.sh"
fi

if [ -r "$MODDIR/lib/props.sh" ]; then
  # shellcheck source=lib/props.sh
  . "$MODDIR/lib/props.sh"
  cs_clear_system_prop "$MODDIR" || true
  rm -f "$CS_STATE_DIR/.purged_leaked_persist_v1" "$CS_STATE_DIR/.purged_leaked_persist_v2" "$CS_STATE_DIR/.purged_leaked_persist_v3" "$CS_STATE_DIR/.cleared_hos3_stuck_blur_v3" 2>/dev/null || true
  cs_purge_leaked_persist_props || true
fi

if [ -r "$MODDIR/lib/settings_tx.sh" ]; then
  # shellcheck source=lib/settings_tx.sh
  . "$MODDIR/lib/settings_tx.sh"
  cs_settings_rollback_all || true
fi

if [ -d "$CS_STATE_DIR" ]; then
  rm -rf "$CS_STATE_DIR"
fi

exit 0
