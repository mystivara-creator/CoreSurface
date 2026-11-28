#!/system/bin/sh
# CoreSurface v1.0.0 - KernelSU-Next / Magisk Interactive Volume-Key Installer
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

_cs_cfg_write_key() {
  _cs_cw_file=$1
  _cs_cw_key=$2
  _cs_cw_val=$3
  _cs_cw_tmp="${_cs_cw_file}.tmp.$$"
  if [ -r "$_cs_cw_file" ]; then
    awk -F '=' -v k="$_cs_cw_key" '$1 != k { print $0 }' "$_cs_cw_file" > "$_cs_cw_tmp"
  else
    : > "$_cs_cw_tmp"
  fi
  printf '%s=%s\n' "$_cs_cw_key" "$_cs_cw_val" >> "$_cs_cw_tmp"
  mv -f "$_cs_cw_tmp" "$_cs_cw_file"
}

# Probe timeout syntax once (Toybox/GNU uses `timeout <sec>`, older BusyBox uses `timeout -t <sec>`)
_cs_timeout_run() {
  _cs_tr_sec=$1
  shift
  if timeout 1 true >/dev/null 2>&1; then
    timeout "$_cs_tr_sec" "$@"
  else
    timeout -t "$_cs_tr_sec" "$@"
  fi
}

# Non-hanging Volume Up / Volume Down reader (returns: 0 + prints UP|DOWN, 1=timeout, 2=non-interactive)
# Kills the background getevent immediately upon key capture so the pipe never stalls until timeout!
_cs_read_vol_key() {
  _cs_vk_timeout=${1:-10}
  [ "${CORESURFACE_NONINTERACTIVE:-0}" = "1" ] && return 2
  command -v getevent >/dev/null 2>&1 || return 2
  command -v timeout >/dev/null 2>&1 || return 2

  _cs_vk_base="${_cs_state_dir:-/tmp}/.vk.$$"
  _cs_vk_res="${_cs_vk_base}.res"
  _cs_vk_pid="${_cs_vk_base}.pid"
  rm -f "$_cs_vk_res" "$_cs_vk_pid" 2>/dev/null || true

  # shellcheck disable=SC2016
  _cs_timeout_run "$_cs_vk_timeout" sh -c '
    res=$1
    pidf=$2
    (
      getevent -lq 2>/dev/null &
      gpid=$!
      printf "%s\n" "$gpid" > "$pidf"
      wait "$gpid" 2>/dev/null
    ) | while IFS= read -r line; do
      case "$line" in
        *KEY_VOLUMEUP*DOWN*|*KEY_VOLUMEUP*00000001*)
          printf "UP\n" > "$res"
          gpid=$(cat "$pidf" 2>/dev/null || true)
          if [ -n "$gpid" ]; then kill "$gpid" 2>/dev/null || true; fi
          exit 0
          ;;
        *KEY_VOLUMEDOWN*DOWN*|*KEY_VOLUMEDOWN*00000001*)
          printf "DOWN\n" > "$res"
          gpid=$(cat "$pidf" 2>/dev/null || true)
          if [ -n "$gpid" ]; then kill "$gpid" 2>/dev/null || true; fi
          exit 0
          ;;
      esac
    done
  ' sh "$_cs_vk_res" "$_cs_vk_pid" >/dev/null 2>&1 || true

  _cs_vk_out=""
  [ -r "$_cs_vk_res" ] && _cs_vk_out=$(head -n 1 "$_cs_vk_res" 2>/dev/null | tr -d '\r')
  _cs_vk_leftover=$(cat "$_cs_vk_pid" 2>/dev/null || true)
  if [ -n "$_cs_vk_leftover" ]; then
    kill "$_cs_vk_leftover" 2>/dev/null || true
  fi
  rm -f "$_cs_vk_res" "$_cs_vk_pid" 2>/dev/null || true

  case "$_cs_vk_out" in
    UP)   printf 'UP\n'; return 0 ;;
    DOWN) printf 'DOWN\n'; return 0 ;;
    *)    return 1 ;;
  esac
}

_cs_tier_label() {
  case "$1" in
    1) printf 'Auto (Smart Recommendation: %s)' "${CS_DETECTED_TIER_LABEL:-Auto}" ;;
    2) printf 'Lite (Entry / Mid Non-Pro — Standard Blur, No Advanced Textures)' ;;
    3) printf 'Balanced Pro (Mid Pro/Pro+ Feel — Daily Flagship Suite)' ;;
    4) printf 'Max Flagship (Full Capability Suite + True Physics Motion)' ;;
  esac
}

_cs_tier_key() {
  case "$1" in
    1) printf 'auto' ;;
    2) printf 'low' ;;
    3) printf 'balanced_pro' ;;
    4) printf 'flagship' ;;
  esac
}

_cs_run_vol_selector() {
  _cs_vs_cfg=$1

  # Only prompt interactively if getevent + timeout are available and not in automated test mode
  [ "${CORESURFACE_NONINTERACTIVE:-0}" = "1" ] && return 0
  command -v getevent >/dev/null 2>&1 || return 0
  command -v timeout >/dev/null 2>&1 || return 0

  # Select 4-Tier Mode
  _cs_sel=1
  case "${CFG_TIER_MODE:-auto}" in
    low)          _cs_sel=2 ;;
    balanced_pro) _cs_sel=3 ;;
    flagship)     _cs_sel=4 ;;
    *)            _cs_sel=1 ;;
  esac

  _cs_ui_print ""
  _cs_ui_print "================================================"
  _cs_ui_print "  SELECT CORESURFACE TIER MODE (Volume Keys)"
  _cs_ui_print "  [Vol+] = Next Option  |  [Vol-] = Confirm"
  _cs_ui_print "  (Wait 10s to keep current selection)"
  _cs_ui_print "================================================"
  _cs_ui_print "  1. $(_cs_tier_label 1)"
  _cs_ui_print "  2. $(_cs_tier_label 2)"
  _cs_ui_print "  3. $(_cs_tier_label 3)"
  _cs_ui_print "  4. $(_cs_tier_label 4)"
  _cs_ui_print "-> Selected: [$_cs_sel] $(_cs_tier_label "$_cs_sel")"

  _cs_loops=0
  while [ "$_cs_loops" -lt 20 ]; do
    _cs_loops=$((_cs_loops + 1))
    _cs_key=$(_cs_read_vol_key 10)
    _cs_krc=$?
    if [ "$_cs_krc" -ne 0 ]; then
      _cs_ui_print "- Timeout: keeping [$_cs_sel] $(_cs_tier_label "$_cs_sel")"
      break
    fi
    if [ "$_cs_key" = "UP" ]; then
      _cs_sel=$(( (_cs_sel % 4) + 1 ))
      _cs_ui_print "-> Selected: [$_cs_sel] $(_cs_tier_label "$_cs_sel")"
    else
      _cs_ui_print "- Confirmed: [$_cs_sel] $(_cs_tier_label "$_cs_sel")"
      break
    fi
  done

  _cs_chosen_tier=$(_cs_tier_key "$_cs_sel")
  _cs_cfg_write_key "$_cs_vs_cfg" "CS_TIER_MODE" "$_cs_chosen_tier"
}

_cs_modpath=${MODPATH:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}
_cs_state_dir=${CORESURFACE_STATE_DIR:-/data/adb/coresurface}
_cs_rom_supported="0"

_cs_ui_print "- Installing CoreSurface v1.3.0 (100% Standalone Flagship Experience)"

mkdir -p "$_cs_state_dir" 2>/dev/null || true

if [ ! -f "$_cs_state_dir/config.prop" ] && [ -r "$_cs_modpath/defaults/config.prop" ]; then
  cp "$_cs_modpath/defaults/config.prop" "$_cs_state_dir/config.prop"
  chmod 0644 "$_cs_state_dir/config.prop" 2>/dev/null || true
  _cs_ui_print "- Installed default configuration to ${_cs_state_dir}/config.prop"
else
  # Ensure newly added keys exist when upgrading an older config.prop
  if [ -r "$_cs_modpath/defaults/config.prop" ]; then
    while IFS='=' read -r _cs_dk _cs_dv || [ -n "$_cs_dk" ]; do
      case "$_cs_dk" in
        ''|'#'*) continue ;;
        CS_*|FEAT_*)
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
    _cs_ui_print "- Detected ROM: ${CS_ROM_FAMILY} (${CS_ROM_VERSION}) | SDK ${CS_ANDROID_SDK}"
    _cs_ui_print "- Detected RAM: ${CS_RAM_MB} MB | Auto Class: ${CS_DETECTED_TIER_LABEL}"

    # Interactive Volume Up / Volume Down 4-Tier Selector
    _cs_run_vol_selector "$_cs_state_dir/config.prop"

    # Reload & resolve final selected configuration
    cs_load_config "$_cs_state_dir/config.prop"
    cs_resolve_features
    _cs_ui_print "- Active Tier: ${CS_EFF_TIER_LABEL}"
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
    if [ -r "$_cs_modpath/lib/xml_patcher.sh" ]; then
      # shellcheck source=lib/xml_patcher.sh
      . "$_cs_modpath/lib/xml_patcher.sh"
      cs_probe_hw_fps || true
    fi
    cs_rro_stage "$_cs_modpath" || true
    _cs_ui_print "- Staged ${CS_RRO_COUNT:-0} clean-room RRO overlay(s) for next boot"
    # On KernelSU / KernelSU-Next without a metamodule, warn user that RRO needs meta-overlayfs
    if [ "${KSU:-false}" = "true" ] && [ "${CS_RRO_COUNT:-0}" -gt 0 ]; then
      if [ ! -e /data/adb/metamodule ] && [ ! -d /data/adb/modules/meta-overlayfs ]; then
        _cs_ui_print "! Note (KernelSU-Next): Install 'meta-overlayfs' metamodule so RRO overlays mount cleanly"
      fi
    fi
  else
    cs_rro_clear "$_cs_modpath" || true
  fi
fi

# Remove any staged legacy Engine APK left over from earlier builds
rm -f "$_cs_state_dir/CoreSurfaceEngine.apk" "$_cs_state_dir/.engine_installed.sig" 2>/dev/null || true

# Reset boot strikes & clear stale Safe-Mode cleanly on fresh install or upgrade
printf '0\n' > "$_cs_state_dir/boot_strikes" 2>/dev/null || true
rm -f "$_cs_modpath/disable" 2>/dev/null || true
if command -v cs_state_set >/dev/null 2>&1; then
  _cs_prev_wd=$(cs_state_get "WATCHDOG_STATUS" 2>/dev/null || true)
  if [ "$_cs_prev_wd" = "safe_mode_disabled" ]; then
    cs_state_set "WATCHDOG_STATUS" "pending_reboot" || true
    cs_state_set "WATCHDOG_REASON" "reinstalled_clean" || true
  fi
fi

_cs_set_exec "$_cs_modpath/post-fs-data.sh"
_cs_set_exec "$_cs_modpath/service.sh"
_cs_set_exec "$_cs_modpath/action.sh"
_cs_set_exec "$_cs_modpath/uninstall.sh"
_cs_set_exec "$_cs_modpath/lib/detect.sh"
_cs_set_exec "$_cs_modpath/lib/watchdog.sh"
_cs_set_exec "$_cs_modpath/lib/props.sh"
_cs_set_exec "$_cs_modpath/lib/xml_patcher.sh"
_cs_set_exec "$_cs_modpath/lib/rro.sh"
_cs_set_exec "$_cs_modpath/lib/settings_tx.sh"
_cs_set_exec "$_cs_modpath/lib/verifier.sh"
_cs_set_exec "$_cs_modpath/lib/os_bug_logic.sh"
_cs_set_exec "$_cs_modpath/lib/webui_ctl.sh"

_cs_ui_print "- Watchdog armed (auto safe-mode disable after 2 consecutive failed boots)"
_cs_ui_print "- 100% Standalone Pure User-Space | 0 KB Background Daemon | Zero Gimmick"
