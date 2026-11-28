#!/system/bin/sh
# CoreSurface v1.4.0 - Root Manager Action Button (KernelSU-Next / Magisk 28+ / APatch)
# Runs instant live hot-sync & re-verification and prints a clean diagnostic summary.

MODDIR=${CORESURFACE_MODDIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}

printf '================================================\n'
printf '  CoreSurface v1.4.0 - Live Sync & Diagnostics\n'
printf '================================================\n'

if [ ! -r "$MODDIR/lib/webui_ctl.sh" ]; then
  printf 'ERROR: %s/lib/webui_ctl.sh not found.\n' "$MODDIR" >&2
  exit 1
fi

sh "$MODDIR/lib/webui_ctl.sh" hot-sync || true
printf '\n'
sh "$MODDIR/lib/webui_ctl.sh" diag-report || true
printf '\nTip: Open CoreSurface WebUI in KernelSU-Next / MMRL for 4-Tier & Flagship controls.\n'
exit 0
