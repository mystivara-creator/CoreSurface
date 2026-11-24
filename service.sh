#!/system/bin/sh
# CoreSurface v1.0.0 - Late Start Service (SystemUI Health Watchdog)
# Waits for sys.boot_completed=1, allows a grace window for com.android.systemui,
# then verifies continuous PID stability for >= 30s before resetting boot_strikes=0.

MODDIR=${CORESURFACE_MODDIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}

# shellcheck source=lib/watchdog.sh
. "$MODDIR/lib/watchdog.sh"

_cs_cur_status=$(cs_state_get "WATCHDOG_STATUS")
case "$_cs_cur_status" in
  unsupported_rom|safe_mode_disabled)
    exit 0
    ;;
esac

cs_watchdog_monitor_systemui || true
exit 0
