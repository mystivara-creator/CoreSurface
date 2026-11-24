#!/system/bin/sh
# CoreSurface v1.0.0 - Clean Uninstall Script
# Removes CoreSurface state, logs, and configuration directory.

CS_STATE_DIR=${CORESURFACE_STATE_DIR:-/data/adb/coresurface}

if [ -d "$CS_STATE_DIR" ]; then
  rm -rf "$CS_STATE_DIR"
fi

exit 0
