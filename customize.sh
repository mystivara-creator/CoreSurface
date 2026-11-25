#!/system/bin/sh
# CoreSurface v1.0.0 - KernelSU-Next / Magisk Installer Script
# IMPORTANT: KernelSU-Next sources customize.sh in its installer shell.
# NEVER enable `set -e` or `set -u` globally here.

_cs_ui_print() {
  if command -v ui_print >/dev/null 2>&1; then
    ui_print "$1"
  else
    printf '%s\n' "$1"
  fi
}

_cs_set_exec() {
  _cs_target=$1
  [ -f "$_cs_target" ] || return 0
  if command -v set_perm >/dev/null 2>&1; then
    set_perm "$_cs_target" 0 0 0755
  else
    chmod 0755 "$_cs_target"
  fi
}

_cs_modpath=${MODPATH:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}
_cs_state_dir=${CORESURFACE_STATE_DIR:-/data/adb/coresurface}
_cs_rom_supported="0"

_cs_ui_print "- Installing CoreSurface v1.0.0 (Clean-Room HyperOS User-Space Suite)"

mkdir -p "$_cs_state_dir" 2>/dev/null || true

if [ ! -f "$_cs_state_dir/config.prop" ] && [ -r "$_cs_modpath/defaults/config.prop" ]; then
  cp "$_cs_modpath/defaults/config.prop" "$_cs_state_dir/config.prop"
  chmod 0644 "$_cs_state_dir/config.prop" 2>/dev/null || true
  _cs_ui_print "- Installed default granular configuration to ${_cs_state_dir}/config.prop"
else
  # Ensure newly added granular keys exist when upgrading an older config.prop
  if [ -r "$_cs_modpath/defaults/config.prop" ]; then
    while IFS='=' read -r _cs_dk _cs_dv || [ -n "$_cs_dk" ]; do
      case "$_cs_dk" in
        ''|'#'*) continue ;;
        FEAT_*)
          if ! grep -q "^${_cs_dk}=" "$_cs_state_dir/config.prop" 2>/dev/null; then
            printf '%s=%s\n' "$_cs_dk" "$_cs_dv" >> "$_cs_state_dir/config.prop"
          fi
          ;;
      esac
    done < "$_cs_modpath/defaults/config.prop"
  fi
  _cs_ui_print "- Preserved existing configuration at ${_cs_state_dir}/config.prop"
fi

if [ -r "$_cs_modpath/lib/detect.sh" ]; then
  # shellcheck source=lib/detect.sh
  . "$_cs_modpath/lib/detect.sh"
  if cs_detect_rom; then
    _cs_rom_supported="1"
    cs_detect_ram_tier
    cs_load_config "$_cs_state_dir/config.prop"
    cs_resolve_features
    _cs_ui_print "- Detected ROM: ${CS_ROM_FAMILY} (${CS_ROM_VERSION}) | SDK ${CS_ANDROID_SDK}"
    _cs_ui_print "- Detected RAM: ${CS_RAM_MB} MB (Tier: ${CS_RAM_TIER_LABEL})"
  else
    _cs_ui_print "! Non-HyperOS/MIUI ROM detected (SDK ${CS_ANDROID_SDK})"
    _cs_ui_print "! CoreSurface will stay idle (unsupported_rom) and will not modify any properties"
  fi
fi

# Stage clean-room RRO overlays and remove any legacy system.prop on install/upgrade
if [ -r "$_cs_modpath/lib/watchdog.sh" ] && [ -r "$_cs_modpath/lib/rro.sh" ] && [ -r "$_cs_modpath/lib/props.sh" ]; then
  # shellcheck source=lib/watchdog.sh
  . "$_cs_modpath/lib/watchdog.sh"
  # shellcheck source=lib/rro.sh
  . "$_cs_modpath/lib/rro.sh"
  # shellcheck source=lib/props.sh
  . "$_cs_modpath/lib/props.sh"
  cs_clear_system_prop "$_cs_modpath" || true
  if [ "$_cs_rom_supported" = "1" ]; then
    cs_rro_stage "$_cs_modpath" || true
    _cs_ui_print "- Staged ${CS_RRO_COUNT:-0} clean-room RRO overlay(s) for next boot"
  else
    cs_rro_clear "$_cs_modpath" || true
  fi
fi

# Stage clean-room CoreSurface Flagship Motion Engine APK for automatic install after boot
if [ -r "$_cs_modpath/engine/CoreSurfaceEngine.apk" ]; then
  cp "$_cs_modpath/engine/CoreSurfaceEngine.apk" "$_cs_state_dir/CoreSurfaceEngine.apk" 2>/dev/null || true
  chmod 0644 "$_cs_state_dir/CoreSurfaceEngine.apk" 2>/dev/null || true
  _cs_ui_print "- Staged CoreSurfaceEngine.apk (Pure Flagship Motion & Experience LSPosed Engine)"
fi

# Reset boot strikes cleanly on fresh install or upgrade
printf '0\n' > "$_cs_state_dir/boot_strikes" 2>/dev/null || true

_cs_set_exec "$_cs_modpath/post-fs-data.sh"
_cs_set_exec "$_cs_modpath/service.sh"
_cs_set_exec "$_cs_modpath/uninstall.sh"
_cs_set_exec "$_cs_modpath/lib/detect.sh"
_cs_set_exec "$_cs_modpath/lib/watchdog.sh"
_cs_set_exec "$_cs_modpath/lib/props.sh"
_cs_set_exec "$_cs_modpath/lib/xml_patcher.sh"
_cs_set_exec "$_cs_modpath/lib/rro.sh"
_cs_set_exec "$_cs_modpath/lib/settings_tx.sh"
_cs_set_exec "$_cs_modpath/lib/verifier.sh"
_cs_set_exec "$_cs_modpath/lib/webui_ctl.sh"

_cs_ui_print "- Watchdog armed (auto safe-mode disable on 2 consecutive failed boots)"
_cs_ui_print "- Architecture: Zero-Gimmick Base + Native Folme Motion Engine (100% Original UI)"
_cs_ui_print "- Enable 'CoreSurface Engine' in LSPosed (SystemUI, MiuiHome, MiuiAod) for live motion curves"
