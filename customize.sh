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

# Non-hanging Volume Up / Volume Down reader (returns: 0 + prints UP|DOWN, 1=timeout, 2=non-interactive)
_cs_read_vol_key() {
  _cs_vk_timeout=${1:-10}
  [ "${CORESURFACE_NONINTERACTIVE:-0}" = "1" ] && return 2
  command -v getevent >/dev/null 2>&1 || return 2
  command -v timeout >/dev/null 2>&1 || return 2

  # shellcheck disable=SC2016
  _cs_vk_out=$(timeout "$_cs_vk_timeout" sh -c '
    getevent -lq 2>/dev/null | while IFS= read -r line; do
      case "$line" in
        *KEY_VOLUMEUP*DOWN*)   printf "UP\n"; exit 0 ;;
        *KEY_VOLUMEDOWN*DOWN*) printf "DOWN\n"; exit 0 ;;
      esac
    done
  ' 2>/dev/null || true)

  case "$_cs_vk_out" in
    UP)   printf 'UP\n'; return 0 ;;
    DOWN) printf 'DOWN\n'; return 0 ;;
    *)    return 1 ;;
  esac
}

_cs_tier_label() {
  case "$1" in
    1) printf 'Auto (Deteksi RAM & Kelas HP: %s)' "${CS_DETECTED_TIER_LABEL:-Auto}" ;;
    2) printf 'Low (Mid Non-Pro / Entry — Blur Standar, Tanpa Advanced Textures)' ;;
    3) printf 'Balance Pro / Pro+ (Mid-Range Pro/Pro+ — Seimbang & Responsif)' ;;
    4) printf 'Flagship Tier (Pengalaman Flagship Penuh — Tetap Ringan)' ;;
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

_cs_motion_label() {
  case "$1" in
    1) printf 'HyperOS 4 Flagship (Tegas & Ringan 60/120 Hz)' ;;
    2) printf 'iOS / ColorOS 17 Silk Fluid (Halus & Mengalir)' ;;
    3) printf 'Stock ROM (Kurva Bawaan)' ;;
  esac
}

_cs_motion_key() {
  case "$1" in
    1) printf 'hyperos4' ;;
    2) printf 'silk' ;;
    3) printf '0' ;;
  esac
}

_cs_run_vol_selector() {
  _cs_vs_cfg=$1

  # Only prompt interactively if getevent + timeout are available and not in automated test mode
  [ "${CORESURFACE_NONINTERACTIVE:-0}" = "1" ] && return 0
  command -v getevent >/dev/null 2>&1 || return 0
  command -v timeout >/dev/null 2>&1 || return 0

  # Step 1: Select 4-Tier Mode
  _cs_sel=1
  case "${CFG_TIER_MODE:-auto}" in
    low)          _cs_sel=2 ;;
    balanced_pro) _cs_sel=3 ;;
    flagship)     _cs_sel=4 ;;
    *)            _cs_sel=1 ;;
  esac

  _cs_ui_print ""
  _cs_ui_print "================================================"
  _cs_ui_print "  PILIH MODE TIER CORESURFACE (Volume Control)"
  _cs_ui_print "  [Vol+] = Ganti Mode  |  [Vol-] = Pilih"
  _cs_ui_print "  (Diam 10 detik = simpan pilihan saat ini)"
  _cs_ui_print "================================================"
  _cs_ui_print "  1. $(_cs_tier_label 1)"
  _cs_ui_print "  2. $(_cs_tier_label 2)"
  _cs_ui_print "  3. $(_cs_tier_label 3)"
  _cs_ui_print "  4. $(_cs_tier_label 4)"
  _cs_ui_print "-> Aktif: [$_cs_sel] $(_cs_tier_label "$_cs_sel")"

  _cs_loops=0
  while [ "$_cs_loops" -lt 20 ]; do
    _cs_loops=$((_cs_loops + 1))
    _cs_key=$(_cs_read_vol_key 10)
    _cs_krc=$?
    if [ "$_cs_krc" -ne 0 ]; then
      _cs_ui_print "- Timeout: menggunakan [$_cs_sel] $(_cs_tier_label "$_cs_sel")"
      break
    fi
    if [ "$_cs_key" = "UP" ]; then
      _cs_sel=$(( (_cs_sel % 4) + 1 ))
      _cs_ui_print "-> Aktif: [$_cs_sel] $(_cs_tier_label "$_cs_sel")"
    else
      _cs_ui_print "- Terpilih: [$_cs_sel] $(_cs_tier_label "$_cs_sel")"
      break
    fi
  done

  _cs_chosen_tier=$(_cs_tier_key "$_cs_sel")
  _cs_cfg_write_key "$_cs_vs_cfg" "CS_TIER_MODE" "$_cs_chosen_tier"

  # Step 2: Select Live Motion Profile
  _cs_msel=1
  if [ "$_cs_chosen_tier" = "flagship" ]; then
    _cs_msel=2
  fi
  case "${CFG_FEAT_MOTION_PROFILE:-}" in
    silk)     _cs_msel=2 ;;
    0)        _cs_msel=3 ;;
  esac

  _cs_ui_print ""
  _cs_ui_print "  PILIH PROFIL ANIMASI FOLME (60/120 Hz)"
  _cs_ui_print "  [Vol+] = Ganti Profil  |  [Vol-] = Pilih (8 detik = default)"
  _cs_ui_print "  1. $(_cs_motion_label 1)"
  _cs_ui_print "  2. $(_cs_motion_label 2)"
  _cs_ui_print "  3. $(_cs_motion_label 3)"
  _cs_ui_print "-> Aktif: [$_cs_msel] $(_cs_motion_label "$_cs_msel")"

  _cs_loops=0
  while [ "$_cs_loops" -lt 15 ]; do
    _cs_loops=$((_cs_loops + 1))
    _cs_key=$(_cs_read_vol_key 8)
    _cs_krc=$?
    if [ "$_cs_krc" -ne 0 ]; then
      _cs_ui_print "- Timeout: menggunakan [$_cs_msel] $(_cs_motion_label "$_cs_msel")"
      break
    fi
    if [ "$_cs_key" = "UP" ]; then
      _cs_msel=$(( (_cs_msel % 3) + 1 ))
      _cs_ui_print "-> Aktif: [$_cs_msel] $(_cs_motion_label "$_cs_msel")"
    else
      _cs_ui_print "- Terpilih: [$_cs_msel] $(_cs_motion_label "$_cs_msel")"
      break
    fi
  done

  _cs_chosen_motion=$(_cs_motion_key "$_cs_msel")
  _cs_cfg_write_key "$_cs_vs_cfg" "FEAT_MOTION_PROFILE" "$_cs_chosen_motion"
}

_cs_modpath=${MODPATH:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}
_cs_state_dir=${CORESURFACE_STATE_DIR:-/data/adb/coresurface}
_cs_rom_supported="0"

_cs_ui_print "- Installing CoreSurface v1.0.0 (Pure Flagship Motion & 4-Tier Experience)"

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

    # Interactive Volume Up / Volume Down 4-Tier & Motion Profile Selector
    _cs_run_vol_selector "$_cs_state_dir/config.prop"

    # Reload & resolve final selected configuration
    cs_load_config "$_cs_state_dir/config.prop"
    cs_resolve_features
    _cs_ui_print "- Active Tier: ${CS_EFF_TIER_LABEL} | Motion: ${EFF_FEAT_MOTION_PROFILE}"
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
  _cs_ui_print "- Staged CoreSurfaceEngine.apk (~33 KB, optional LSPosed Motion & Recents/AOD Engine)"
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
_cs_ui_print "- 100% Original HyperOS UI | Custom Color Expert ON | Zero Gimmick"
_cs_ui_print "- Optional: Enable 'CoreSurface Engine' in LSPosed (SystemUI, MiuiHome, MiuiAod) for 60/120 Hz Folme & Recents/AOD fixes"
