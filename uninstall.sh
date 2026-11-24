#!/system/bin/sh
# CoreSurface v1.0.0 - Clean Uninstall Script
# Rolls back all transactional Android `settings` overrides before removing state directory.

MODDIR=${CORESURFACE_MODDIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}
CS_STATE_DIR=${CORESURFACE_STATE_DIR:-/data/adb/coresurface}

if [ -r "$MODDIR/lib/watchdog.sh" ]; then
  # shellcheck source=lib/watchdog.sh
  . "$MODDIR/lib/watchdog.sh"
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
