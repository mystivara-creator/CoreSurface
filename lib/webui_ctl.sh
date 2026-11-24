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
CS_VERIFY_FILE="$CS_STATE_DIR/verify.state"
CS_OVERRIDDEN_PROPS_FILE="$CS_STATE_DIR/overridden_props.list"
CS_COREFLOW_DIR=${CORESURFACE_COREFLOW_DIR:-/data/adb/modules/cfae_framework}

cs_ensure_config() {
  cs_watchdog_init_dir || return 1
  if [ ! -f "$CS_CONFIG_FILE" ] && [ -r "$MODDIR/defaults/config.prop" ]; then
    cp "$MODDIR/defaults/config.prop" "$CS_CONFIG_FILE"
  fi
}

cs_verify_get() {
  _cs_vgk=$1
  if [ -r "$CS_VERIFY_FILE" ]; then
    awk -F '=' -v k="$_cs_vgk" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$CS_VERIFY_FILE" 2>/dev/null || true
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

cs_add_pending_key() {
  _cs_pk_add=$1
  _cs_cur=$(cs_state_get "PENDING_KEYS")
  case ",$_cs_cur," in
    *",$_cs_pk_add,"*) return 0 ;;
  esac
  if [ -z "$_cs_cur" ]; then
    cs_state_set "PENDING_KEYS" "$_cs_pk_add"
  else
    cs_state_set "PENDING_KEYS" "${_cs_cur},${_cs_pk_add}"
  fi
}

cs_cmd_status() {
  cs_ensure_config || true
  cs_detect_rom || true
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_features

  _cs_wd_status=$(cs_state_get "WATCHDOG_STATUS")
  _cs_wd_reason=$(cs_state_get "WATCHDOG_REASON")
  _cs_strikes=$(cs_read_strikes)
  _cs_cf_guard=$(cs_detect_coreflow_guard)
  _cs_pending_keys=$(cs_state_get "PENDING_KEYS")
  _cs_disabled="0"
  if [ -f "$MODDIR/disable" ]; then
    _cs_disabled="1"
    if [ -z "$_cs_wd_status" ] || [ "$_cs_wd_status" = "healthy" ]; then
      _cs_wd_status="safe_mode_disabled"
    fi
  fi

  _cs_xml_status=$(cs_state_get "XML_STATUS")
  _cs_xml_reason=$(cs_state_get "XML_REASON")
  _cs_xml_source=$(cs_state_get "XML_SOURCE")
  _cs_xml_tags=$(cs_state_get "XML_PATCHED_TAGS")

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
  printf 'coreflow_guard=%s\n' "$_cs_cf_guard"
  printf 'pending_keys=%s\n' "${_cs_pending_keys:-}"

  printf 'cfg_feat_blur=%s\n' "$CFG_FEAT_BLUR"
  printf 'cfg_feat_animations=%s\n' "$CFG_FEAT_ANIMATIONS"
  printf 'cfg_feat_xml_patcher=%s\n' "$CFG_FEAT_XML_PATCHER"
  printf 'cfg_feat_multitask=%s\n' "$CFG_FEAT_MULTITASK"
  printf 'cfg_feat_display_hz=%s\n' "$CFG_FEAT_DISPLAY_HZ"
  printf 'cfg_feat_hyperai=%s\n' "$CFG_FEAT_HYPERAI"
  printf 'cfg_feat_aod_unlock=%s\n' "$CFG_FEAT_AOD_UNLOCK"

  printf 'eff_feat_blur=%s\n' "$EFF_FEAT_BLUR"
  printf 'eff_feat_animations=%s\n' "$EFF_FEAT_ANIMATIONS"
  printf 'eff_feat_xml_patcher=%s\n' "$EFF_FEAT_XML_PATCHER"
  printf 'eff_feat_multitask=%s\n' "$EFF_FEAT_MULTITASK"
  printf 'eff_feat_display_hz=%s\n' "$EFF_FEAT_DISPLAY_HZ"
  printf 'eff_feat_hyperai=%s\n' "$EFF_FEAT_HYPERAI"
  printf 'eff_feat_aod_unlock=%s\n' "$EFF_FEAT_AOD_UNLOCK"

  printf 'xml_status=%s\n' "${_cs_xml_status:-skipped}"
  printf 'xml_reason=%s\n' "${_cs_xml_reason:-none}"
  printf 'xml_source=%s\n' "${_cs_xml_source:-none}"
  printf 'xml_patched_tags=%s\n' "${_cs_xml_tags:-0}"

  printf 'verify_feat_blur=%s\n' "$(cs_verify_get VERIFY_FEAT_BLUR)"
  printf 'verify_feat_animations=%s\n' "$(cs_verify_get VERIFY_FEAT_ANIMATIONS)"
  printf 'verify_feat_xml_patcher=%s\n' "$(cs_verify_get VERIFY_FEAT_XML_PATCHER)"
  printf 'verify_feat_multitask=%s\n' "$(cs_verify_get VERIFY_FEAT_MULTITASK)"
  printf 'verify_feat_display_hz=%s\n' "$(cs_verify_get VERIFY_FEAT_DISPLAY_HZ)"
  printf 'verify_feat_hyperai=%s\n' "$(cs_verify_get VERIFY_FEAT_HYPERAI)"
  printf 'verify_feat_aod_unlock=%s\n' "$(cs_verify_get VERIFY_FEAT_AOD_UNLOCK)"
  printf 'verify_xml_mount=%s\n' "$(cs_verify_get VERIFY_XML_MOUNT)"
  printf 'verify_props_total=%s\n' "$(cs_verify_get VERIFY_PROPS_TOTAL)"
  printf 'verify_props_matched=%s\n' "$(cs_verify_get VERIFY_PROPS_MATCHED)"
  printf 'verify_props_overridden=%s\n' "$(cs_verify_get VERIFY_PROPS_OVERRIDDEN)"

  printf 'props_start\n'
  if [ -r "$CS_PROPS_AUDIT_FILE" ]; then
    cat "$CS_PROPS_AUDIT_FILE"
  fi
  printf 'props_end\n'

  printf 'overridden_start\n'
  if [ -r "$CS_OVERRIDDEN_PROPS_FILE" ]; then
    cat "$CS_OVERRIDDEN_PROPS_FILE"
  fi
  printf 'overridden_end\n'

  printf 'log_start\n'
  if [ -r "$CS_LOG_FILE" ]; then
    tail -n 30 "$CS_LOG_FILE" 2>/dev/null || true
  fi
  printf 'log_end\n'
}

cs_cmd_set() {
  _cs_set_k=$1
  _cs_set_v=$2

  case "$_cs_set_k" in
    FEAT_BLUR|FEAT_ANIMATIONS|FEAT_XML_PATCHER|FEAT_MULTITASK|FEAT_DISPLAY_HZ)
      case "$_cs_set_v" in
        auto|1|0) ;;
        *)
          printf 'Invalid value for %s: %s (expected auto|1|0)\n' "$_cs_set_k" "$_cs_set_v" >&2
          return 1
          ;;
      esac
      ;;
    FEAT_HYPERAI|FEAT_AOD_UNLOCK)
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

  cs_add_pending_key "$_cs_set_k"
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
