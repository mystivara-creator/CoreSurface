#!/system/bin/sh
# CoreSurface - WebUI Control Bridge (called via absolute path by webroot/app.js)
# Self-resolves MODDIR from its own script location.

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MODDIR=${CORESURFACE_MODDIR:-$(dirname -- "$SCRIPT_DIR")}

# shellcheck source=lib/detect.sh
. "$MODDIR/lib/detect.sh"
# shellcheck source=lib/watchdog.sh
. "$MODDIR/lib/watchdog.sh"

CS_CONFIG_FILE="$CS_STATE_DIR/config.prop"
CS_COREFLOW_DIR=${CORESURFACE_COREFLOW_DIR:-/data/adb/modules/cfae_framework}

cs_ensure_config() {
  cs_watchdog_init_dir || return 1
  if [ ! -f "$CS_CONFIG_FILE" ] && [ -r "$MODDIR/defaults/config.prop" ]; then
    cp "$MODDIR/defaults/config.prop" "$CS_CONFIG_FILE"
  fi
}

cs_detect_coreflow_guard() {
  if [ -d "$CS_COREFLOW_DIR" ] && [ ! -f "$CS_COREFLOW_DIR/disable" ]; then
    if pidof coreflowd >/dev/null 2>&1; then
      printf 'active\n'
      return 0
    fi
  fi
  printf 'inactive\n'
}

cs_cmd_status() {
  cs_ensure_config || true
  cs_detect_rom || true
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_tiers

  _cs_wd_status=$(cs_state_get "WATCHDOG_STATUS")
  _cs_wd_reason=$(cs_state_get "WATCHDOG_REASON")
  _cs_strikes=$(cs_read_strikes)
  _cs_cf_guard=$(cs_detect_coreflow_guard)
  _cs_disabled="0"
  if [ -f "$MODDIR/disable" ]; then
    _cs_disabled="1"
    if [ -z "$_cs_wd_status" ] || [ "$_cs_wd_status" = "healthy" ]; then
      _cs_wd_status="safe_mode_disabled"
    fi
  fi

  printf 'module_version=%s\n' "v1.0.0"
  printf 'watchdog_status=%s\n' "${_cs_wd_status:-unknown}"
  printf 'watchdog_reason=%s\n' "${_cs_wd_reason:-none}"
  printf 'boot_strikes=%s\n' "${_cs_strikes:-0}"
  printf 'module_disabled=%s\n' "$_cs_disabled"
  printf 'rom_family=%s\n' "$CS_ROM_FAMILY"
  printf 'rom_version=%s\n' "${CS_ROM_VERSION:-Unknown}"
  printf 'hyperos_major=%s\n' "$CS_HYPEROS_MAJOR"
  printf 'android_sdk=%s\n' "$CS_ANDROID_SDK"
  printf 'ram_mb=%s\n' "$CS_RAM_MB"
  printf 'ram_tier=%s\n' "$CS_RAM_TIER"
  printf 'ram_tier_label=%s\n' "$CS_RAM_TIER_LABEL"
  printf 'cfg_tier1=%s\n' "$CFG_TIER1_VISUAL"
  printf 'cfg_tier2=%s\n' "$CFG_TIER2_MULTITASK"
  printf 'cfg_tier3=%s\n' "$CFG_TIER3_EXPERIMENTAL"
  printf 'cfg_tier3_hyperai=%s\n' "$CFG_TIER3_HYPERAI"
  printf 'cfg_tier3_aod=%s\n' "$CFG_TIER3_AOD_UNLOCK"
  printf 'eff_tier1=%s\n' "$EFF_TIER1"
  printf 'eff_tier1_heavy_blur=%s\n' "$EFF_TIER1_HEAVY_BLUR"
  printf 'eff_tier2=%s\n' "$EFF_TIER2"
  printf 'eff_tier3=%s\n' "$EFF_TIER3"
  printf 'eff_tier3_hyperai=%s\n' "$EFF_TIER3_HYPERAI"
  printf 'eff_tier3_aod=%s\n' "$EFF_TIER3_AOD_UNLOCK"
  printf 'coreflow_guard=%s\n' "$_cs_cf_guard"

  printf 'props_start\n'
  if [ -r "$CS_PROPS_AUDIT_FILE" ]; then
    cat "$CS_PROPS_AUDIT_FILE"
  fi
  printf 'props_end\n'

  printf 'log_start\n'
  if [ -r "$CS_LOG_FILE" ]; then
    tail -n 25 "$CS_LOG_FILE" 2>/dev/null || true
  fi
  printf 'log_end\n'
}

cs_cmd_set() {
  _cs_set_k=$1
  _cs_set_v=$2

  case "$_cs_set_k" in
    TIER1_VISUAL|TIER2_MULTITASK)
      case "$_cs_set_v" in
        auto|1|0) ;;
        *)
          printf 'Invalid value for %s: %s (expected auto|1|0)\n' "$_cs_set_k" "$_cs_set_v" >&2
          return 1
          ;;
      esac
      ;;
    TIER3_EXPERIMENTAL|TIER3_HYPERAI|TIER3_AOD_UNLOCK)
      case "$_cs_set_v" in
        1|0) ;;
        *)
          printf 'Invalid value for %s: %s (expected 1|0)\n' "$_cs_set_k" "$_cs_set_v" >&2
          return 1
          ;;
      esac
      ;;
    *)
      printf 'Unknown config key: %s\n' "$_cs_set_k" >&2
      return 1
      ;;
  esac

  cs_ensure_config || return 1

  _cs_tmp="$CS_CONFIG_FILE.tmp.$$"
  if [ -r "$CS_CONFIG_FILE" ]; then
    awk -F '=' -v k="$_cs_set_k" '$1 != k { print $0 }' "$CS_CONFIG_FILE" > "$_cs_tmp"
  else
    : > "$_cs_tmp"
  fi
  printf '%s=%s\n' "$_cs_set_k" "$_cs_set_v" >> "$_cs_tmp"
  mv -f "$_cs_tmp" "$CS_CONFIG_FILE"

  cs_log "WebUI updated ${_cs_set_k}=${_cs_set_v} (reboot required)."
  printf 'Saved %s=%s. Reboot required to apply.\n' "$_cs_set_k" "$_cs_set_v"
}

cs_cmd_reset_safemode() {
  cs_watchdog_init_dir || return 1
  rm -f "$MODDIR/disable"
  cs_write_strikes "0"
  cs_state_set "WATCHDOG_STATUS" "pending_reboot"
  cs_state_set "WATCHDOG_REASON" "safemode_cleared_by_user"
  cs_log "WebUI cleared Safe-Mode: removed ${MODDIR}/disable, reset boot_strikes=0."
  printf 'Safe-Mode cleared and module re-enabled. Reboot to apply.\n'
}

case "${1:-}" in
  status)
    cs_cmd_status
    ;;
  set)
    cs_cmd_set "${2:-}" "${3:-}"
    ;;
  reset-safemode)
    cs_cmd_reset_safemode
    ;;
  *)
    printf 'Usage: %s {status|set <KEY> <VALUE>|reset-safemode}\n' "$0" >&2
    exit 1
    ;;
esac
