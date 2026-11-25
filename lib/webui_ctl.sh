#!/system/bin/sh
# CoreSurface - WebUI Control Bridge (called via absolute path by webroot/app.js)
# Self-resolves MODDIR from its own script location.
# Supports: status | set <KEY> <VAL> | preset <stock-safe|balanced|flagship-max>
#           | hot-sync | install-engine | diag-report | reset-safemode

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MODDIR=${CORESURFACE_MODDIR:-$(dirname -- "$SCRIPT_DIR")}

# shellcheck source=lib/detect.sh
. "$MODDIR/lib/detect.sh"
# shellcheck source=lib/watchdog.sh
. "$MODDIR/lib/watchdog.sh"
# shellcheck source=lib/rro.sh
. "$MODDIR/lib/rro.sh"
# shellcheck source=lib/props.sh
. "$MODDIR/lib/props.sh"
# shellcheck source=lib/settings_tx.sh
. "$MODDIR/lib/settings_tx.sh"
# shellcheck source=lib/verifier.sh
. "$MODDIR/lib/verifier.sh"

CS_CONFIG_FILE="$CS_STATE_DIR/config.prop"
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

cs_write_config_key() {
  _cs_wk=$1
  _cs_wv=$2
  _cs_tmp="$CS_CONFIG_FILE.tmp.$$"
  if [ -r "$CS_CONFIG_FILE" ]; then
    awk -F '=' -v k="$_cs_wk" '$1 != k { print $0 }' "$CS_CONFIG_FILE" > "$_cs_tmp"
  else
    : > "$_cs_tmp"
  fi
  printf '%s=%s\n' "$_cs_wk" "$_cs_wv" >> "$_cs_tmp"
  mv -f "$_cs_tmp" "$CS_CONFIG_FILE"
}

cs_sync_rro_for_next_boot() {
  cs_detect_rom || return 0
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_features
  cs_rro_stage "$MODDIR" || true
  cs_clear_system_prop "$MODDIR" || true
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
  _cs_rro_status=$(cs_state_get "RRO_STATUS")
  _cs_rro_staged=$(cs_state_get "RRO_STAGED_COUNT")
  _cs_vd_status=$(cs_state_get "VIDEO_DEPTH_STATUS")

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

  printf 'cfg_feat_luminous_glass=%s\n' "$CFG_FEAT_LUMINOUS_GLASS"
  printf 'cfg_feat_luminous_tilt=%s\n' "$CFG_FEAT_LUMINOUS_TILT"
  printf 'cfg_feat_living_flow=%s\n' "$CFG_FEAT_LIVING_FLOW"
  printf 'cfg_feat_surgical_guard=%s\n' "$CFG_FEAT_SURGICAL_GUARD"
  printf 'cfg_feat_thermal_lod=%s\n' "$CFG_FEAT_THERMAL_LOD"
  printf 'cfg_feat_blur=%s\n' "$CFG_FEAT_BLUR"
  printf 'cfg_feat_animations=%s\n' "$CFG_FEAT_ANIMATIONS"
  printf 'cfg_feat_xml_patcher=%s\n' "$CFG_FEAT_XML_PATCHER"
  printf 'cfg_feat_rro_overlays=%s\n' "$CFG_FEAT_RRO_OVERLAYS"
  printf 'cfg_feat_video_depth=%s\n' "$CFG_FEAT_VIDEO_DEPTH"
  printf 'cfg_feat_multitask=%s\n' "$CFG_FEAT_MULTITASK"
  printf 'cfg_feat_display_hz=%s\n' "$CFG_FEAT_DISPLAY_HZ"
  printf 'cfg_feat_color_expert=%s\n' "$CFG_FEAT_COLOR_EXPERT"
  printf 'cfg_feat_gallery_pro=%s\n' "$CFG_FEAT_GALLERY_PRO"
  printf 'cfg_feat_aod_unlock=%s\n' "$CFG_FEAT_AOD_UNLOCK"

  printf 'eff_feat_luminous_glass=%s\n' "$EFF_FEAT_LUMINOUS_GLASS"
  printf 'eff_feat_luminous_tilt=%s\n' "$EFF_FEAT_LUMINOUS_TILT"
  printf 'eff_feat_living_flow=%s\n' "$EFF_FEAT_LIVING_FLOW"
  printf 'eff_feat_surgical_guard=%s\n' "$EFF_FEAT_SURGICAL_GUARD"
  printf 'eff_feat_thermal_lod=%s\n' "$EFF_FEAT_THERMAL_LOD"
  printf 'eff_feat_blur=%s\n' "$EFF_FEAT_BLUR"
  printf 'eff_feat_animations=%s\n' "$EFF_FEAT_ANIMATIONS"
  printf 'eff_feat_xml_patcher=%s\n' "$EFF_FEAT_XML_PATCHER"
  printf 'eff_feat_rro_overlays=%s\n' "$EFF_FEAT_RRO_OVERLAYS"
  printf 'eff_feat_video_depth=%s\n' "$EFF_FEAT_VIDEO_DEPTH"
  printf 'eff_feat_multitask=%s\n' "$EFF_FEAT_MULTITASK"
  printf 'eff_feat_display_hz=%s\n' "$EFF_FEAT_DISPLAY_HZ"
  printf 'eff_feat_color_expert=%s\n' "$EFF_FEAT_COLOR_EXPERT"
  printf 'eff_feat_gallery_pro=%s\n' "$EFF_FEAT_GALLERY_PRO"
  printf 'eff_feat_aod_unlock=%s\n' "$EFF_FEAT_AOD_UNLOCK"

  printf 'xml_status=%s\n' "${_cs_xml_status:-skipped}"
  printf 'xml_reason=%s\n' "${_cs_xml_reason:-none}"
  printf 'xml_source=%s\n' "${_cs_xml_source:-none}"
  printf 'xml_patched_tags=%s\n' "${_cs_xml_tags:-0}"

  printf 'rro_status=%s\n' "${_cs_rro_status:-skipped}"
  printf 'rro_staged_count=%s\n' "${_cs_rro_staged:-0}"
  printf 'video_depth_status=%s\n' "${_cs_vd_status:-disabled}"

  printf 'verify_engine_installed=%s\n' "$(cs_verify_get VERIFY_ENGINE_INSTALLED)"
  printf 'verify_engine_active=%s\n' "$(cs_verify_get VERIFY_ENGINE_ACTIVE)"
  printf 'verify_engine_agsl=%s\n' "$(cs_verify_get VERIFY_ENGINE_AGSL)"
  printf 'verify_engine_lod=%s\n' "$(cs_verify_get VERIFY_ENGINE_LOD)"
  printf 'verify_engine_hooks=%s\n' "$(cs_verify_get VERIFY_ENGINE_HOOKS)"
  printf 'verify_engine_views=%s\n' "$(cs_verify_get VERIFY_ENGINE_VIEWS)"
  printf 'verify_engine_toasts=%s\n' "$(cs_verify_get VERIFY_ENGINE_TOASTS)"
  printf 'verify_engine_recents=%s\n' "$(cs_verify_get VERIFY_ENGINE_RECENTS)"
  printf 'verify_engine_flows=%s\n' "$(cs_verify_get VERIFY_ENGINE_FLOWS)"

  printf 'verify_feat_luminous_glass=%s\n' "$(cs_verify_get VERIFY_FEAT_LUMINOUS_GLASS)"
  printf 'verify_feat_luminous_tilt=%s\n' "$(cs_verify_get VERIFY_FEAT_LUMINOUS_TILT)"
  printf 'verify_feat_living_flow=%s\n' "$(cs_verify_get VERIFY_FEAT_LIVING_FLOW)"
  printf 'verify_feat_surgical_guard=%s\n' "$(cs_verify_get VERIFY_FEAT_SURGICAL_GUARD)"
  printf 'verify_feat_thermal_lod=%s\n' "$(cs_verify_get VERIFY_FEAT_THERMAL_LOD)"
  printf 'verify_feat_blur=%s\n' "$(cs_verify_get VERIFY_FEAT_BLUR)"
  printf 'verify_feat_animations=%s\n' "$(cs_verify_get VERIFY_FEAT_ANIMATIONS)"
  printf 'verify_feat_xml_patcher=%s\n' "$(cs_verify_get VERIFY_FEAT_XML_PATCHER)"
  printf 'verify_feat_rro_overlays=%s\n' "$(cs_verify_get VERIFY_FEAT_RRO_OVERLAYS)"
  printf 'verify_feat_video_depth=%s\n' "$(cs_verify_get VERIFY_FEAT_VIDEO_DEPTH)"
  printf 'verify_feat_multitask=%s\n' "$(cs_verify_get VERIFY_FEAT_MULTITASK)"
  printf 'verify_feat_display_hz=%s\n' "$(cs_verify_get VERIFY_FEAT_DISPLAY_HZ)"
  printf 'verify_feat_color_expert=%s\n' "$(cs_verify_get VERIFY_FEAT_COLOR_EXPERT)"
  printf 'verify_feat_gallery_pro=%s\n' "$(cs_verify_get VERIFY_FEAT_GALLERY_PRO)"
  printf 'verify_feat_aod_unlock=%s\n' "$(cs_verify_get VERIFY_FEAT_AOD_UNLOCK)"
  printf 'verify_xml_mount=%s\n' "$(cs_verify_get VERIFY_XML_MOUNT)"
  printf 'verify_rro_active=%s\n' "$(cs_verify_get VERIFY_RRO_ACTIVE)"
  printf 'verify_rro_total=%s\n' "$(cs_verify_get VERIFY_RRO_TOTAL)"
  printf 'verify_props_total=%s\n' "$(cs_verify_get VERIFY_PROPS_TOTAL)"
  printf 'verify_props_matched=%s\n' "$(cs_verify_get VERIFY_PROPS_MATCHED)"
  printf 'verify_props_overridden=%s\n' "$(cs_verify_get VERIFY_PROPS_OVERRIDDEN)"
  printf 'verify_feat_verified=%s\n' "$(cs_verify_get VERIFY_FEAT_VERIFIED)"
  printf 'verify_feat_evaluated=%s\n' "$(cs_verify_get VERIFY_FEAT_EVALUATED)"
  printf 'compat_score_pct=%s\n' "$(cs_verify_get COMPAT_SCORE_PCT)"

  printf 'rro_start\n'
  if [ -r "$CS_RRO_STAGED_LIST" ]; then
    cat "$CS_RRO_STAGED_LIST"
  fi
  printf 'rro_end\n'

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
  _cs_is_live="0"

  case "$_cs_set_k" in
    FEAT_LUMINOUS_GLASS|FEAT_LUMINOUS_TILT|FEAT_LIVING_FLOW|FEAT_SURGICAL_GUARD|FEAT_THERMAL_LOD)
      _cs_is_live="1"
      case "$_cs_set_v" in
        auto|1|0) ;;
        *)
          printf 'Invalid value for %s: %s (expected auto|1|0)\n' "$_cs_set_k" "$_cs_set_v" >&2
          return 1
          ;;
      esac
      ;;
    FEAT_BLUR|FEAT_ANIMATIONS|FEAT_XML_PATCHER|FEAT_RRO_OVERLAYS|FEAT_VIDEO_DEPTH|FEAT_MULTITASK|FEAT_DISPLAY_HZ)
      case "$_cs_set_v" in
        auto|1|0) ;;
        *)
          printf 'Invalid value for %s: %s (expected auto|1|0)\n' "$_cs_set_k" "$_cs_set_v" >&2
          return 1
          ;;
      esac
      ;;
    FEAT_COLOR_EXPERT|FEAT_GALLERY_PRO|FEAT_AOD_UNLOCK)
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
  cs_write_config_key "$_cs_set_k" "$_cs_set_v"

  if [ "$_cs_is_live" = "1" ]; then
    cs_detect_rom || true
    cs_detect_ram_tier
    cs_load_config "$CS_CONFIG_FILE"
    cs_resolve_features
    cs_settings_sync_engine_ipc || true
    cs_verifier_run || true
    cs_log "WebUI live-updated ${_cs_set_k}=${_cs_set_v} (instant reload via Settings.Global IPC, 0 reboot)."
    printf 'LIVE Applied %s=%s (langsung aktif tanpa reboot!).\n' "$_cs_set_k" "$_cs_set_v"
    return 0
  fi

  cs_sync_rro_for_next_boot || true
  if [ "$_cs_set_k" = "FEAT_AOD_UNLOCK" ]; then
    cs_settings_sync_engine_ipc || true
  fi

  cs_add_pending_key "$_cs_set_k"
  cs_log "WebUI updated ${_cs_set_k}=${_cs_set_v} (reboot required for early-boot props/XML/RRO)."
  printf 'Saved %s=%s. Reboot required for early-boot props/XML/RRO.\n' "$_cs_set_k" "$_cs_set_v"
}

cs_cmd_preset() {
  _cs_preset=$1
  cs_ensure_config || return 1

  case "$_cs_preset" in
    stock-safe)
      cs_write_config_key "FEAT_LUMINOUS_GLASS" "0"
      cs_write_config_key "FEAT_LUMINOUS_TILT" "0"
      cs_write_config_key "FEAT_LIVING_FLOW" "auto"
      cs_write_config_key "FEAT_SURGICAL_GUARD" "1"
      cs_write_config_key "FEAT_THERMAL_LOD" "1"
      cs_write_config_key "FEAT_BLUR" "0"
      cs_write_config_key "FEAT_ANIMATIONS" "auto"
      cs_write_config_key "FEAT_XML_PATCHER" "auto"
      cs_write_config_key "FEAT_RRO_OVERLAYS" "0"
      cs_write_config_key "FEAT_VIDEO_DEPTH" "0"
      cs_write_config_key "FEAT_MULTITASK" "0"
      cs_write_config_key "FEAT_DISPLAY_HZ" "0"
      cs_write_config_key "FEAT_COLOR_EXPERT" "0"
      cs_write_config_key "FEAT_GALLERY_PRO" "0"
      cs_write_config_key "FEAT_AOD_UNLOCK" "0"
      ;;
    balanced)
      cs_write_config_key "FEAT_LUMINOUS_GLASS" "auto"
      cs_write_config_key "FEAT_LUMINOUS_TILT" "auto"
      cs_write_config_key "FEAT_LIVING_FLOW" "auto"
      cs_write_config_key "FEAT_SURGICAL_GUARD" "auto"
      cs_write_config_key "FEAT_THERMAL_LOD" "auto"
      cs_write_config_key "FEAT_BLUR" "auto"
      cs_write_config_key "FEAT_ANIMATIONS" "auto"
      cs_write_config_key "FEAT_XML_PATCHER" "auto"
      cs_write_config_key "FEAT_RRO_OVERLAYS" "auto"
      cs_write_config_key "FEAT_VIDEO_DEPTH" "auto"
      cs_write_config_key "FEAT_MULTITASK" "auto"
      cs_write_config_key "FEAT_DISPLAY_HZ" "auto"
      cs_write_config_key "FEAT_COLOR_EXPERT" "0"
      cs_write_config_key "FEAT_GALLERY_PRO" "0"
      cs_write_config_key "FEAT_AOD_UNLOCK" "0"
      ;;
    flagship-max)
      cs_write_config_key "FEAT_LUMINOUS_GLASS" "1"
      cs_write_config_key "FEAT_LUMINOUS_TILT" "1"
      cs_write_config_key "FEAT_LIVING_FLOW" "1"
      cs_write_config_key "FEAT_SURGICAL_GUARD" "1"
      cs_write_config_key "FEAT_THERMAL_LOD" "1"
      cs_write_config_key "FEAT_BLUR" "1"
      cs_write_config_key "FEAT_ANIMATIONS" "1"
      cs_write_config_key "FEAT_XML_PATCHER" "1"
      cs_write_config_key "FEAT_RRO_OVERLAYS" "1"
      cs_write_config_key "FEAT_VIDEO_DEPTH" "1"
      cs_write_config_key "FEAT_MULTITASK" "1"
      cs_write_config_key "FEAT_DISPLAY_HZ" "1"
      ;;
    *)
      printf 'Unknown preset: %s (expected stock-safe|balanced|flagship-max)\n' "$_cs_preset" >&2
      return 1
      ;;
  esac

  cs_sync_rro_for_next_boot || true
  cs_settings_sync_all || true
  cs_verifier_run || true
  cs_state_set "PENDING_KEYS" "FEAT_BLUR,FEAT_ANIMATIONS,FEAT_XML_PATCHER,FEAT_RRO_OVERLAYS,FEAT_VIDEO_DEPTH,FEAT_MULTITASK,FEAT_DISPLAY_HZ"
  cs_log "WebUI applied preset=${_cs_preset} (Live Engine & settings hot-synced; reboot for early-boot props/RRO)."
  printf 'Preset "%s" diterapkan (Luminous/LivingFlow aktif LIVE; reboot untuk prop/RRO).\n' "$_cs_preset"
}

cs_cmd_hot_sync() {
  cs_ensure_config || return 1
  cs_detect_rom || true
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_features
  cs_settings_sync_all || true
  cs_verifier_run || true
  cs_log "WebUI triggered instant Live Engine + settings hot-sync & re-verification."
  printf 'Hot-Apply Live Engine + settings & verifikasi ulang selesai tanpa reboot.\n'
}

cs_cmd_install_engine() {
  _cs_apk="$CS_STATE_DIR/CoreSurfaceEngine.apk"
  [ -r "$_cs_apk" ] || _cs_apk="$MODDIR/engine/CoreSurfaceEngine.apk"
  if [ ! -r "$_cs_apk" ]; then
    printf 'CoreSurfaceEngine.apk tidak ditemukan di modul.\n' >&2
    return 1
  fi
  if ! command -v pm >/dev/null 2>&1; then
    printf 'Perintah pm tidak tersedia.\n' >&2
    return 1
  fi
  _cs_out=$(pm install -r "$_cs_apk" 2>&1 || true)
  case "$_cs_out" in
    *Success*)
      cs_verifier_run || true
      cs_log "WebUI installed/updated CoreSurfaceEngine.apk."
      printf 'CoreSurfaceEngine.apk terpasang! Aktifkan di LSPosed (SystemUI, MiuiHome, MiuiAod).\n'
      return 0
      ;;
  esac
  if command -v su >/dev/null 2>&1; then
    _cs_out=$(su 2000 -c "pm install -r ${_cs_apk}" 2>&1 || true)
    case "$_cs_out" in
      *Success*)
        cs_verifier_run || true
        cs_log "WebUI installed/updated CoreSurfaceEngine.apk via UID 2000."
        printf 'CoreSurfaceEngine.apk terpasang! Aktifkan di LSPosed (SystemUI, MiuiHome, MiuiAod).\n'
        return 0
        ;;
    esac
  fi
  printf 'Gagal memasang APK (%s). Pasang manual dari %s\n' "$_cs_out" "$_cs_apk" >&2
  return 1
}

cs_cmd_diag_report() {
  cs_ensure_config || true
  cs_detect_rom || true
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_features

  printf '=== CoreSurface v1.0.0 Hybrid Diagnostic Report ===\n'
  printf 'ROM: %s (%s) | HyperOS Major: %s | Android SDK: %s\n' \
    "$CS_ROM_FAMILY" "${CS_ROM_VERSION:-Unknown}" "$CS_HYPEROS_MAJOR" "$CS_ANDROID_SDK"
  printf 'RAM: %s MB (%s) | CoreFlow Guard: %s\n' \
    "$CS_RAM_MB" "$CS_RAM_TIER_LABEL" "$(cs_detect_coreflow_guard)"
  printf 'Watchdog: %s (reason=%s, strikes=%s/2)\n' \
    "$(cs_state_get WATCHDOG_STATUS)" "$(cs_state_get WATCHDOG_REASON)" "$(cs_read_strikes)"
  printf 'Compatibility Score: %s%% (%s/%s features verified; props %s/%s matched)\n' \
    "$(cs_verify_get COMPAT_SCORE_PCT)" \
    "$(cs_verify_get VERIFY_FEAT_VERIFIED)" "$(cs_verify_get VERIFY_FEAT_EVALUATED)" \
    "$(cs_verify_get VERIFY_PROPS_MATCHED)" "$(cs_verify_get VERIFY_PROPS_TOTAL)"
  printf 'Luminous Engine: installed=%s active=%s agsl=%s lod=%s hooks=%s views=%s toasts=%s recents=%s flows=%s\n' \
    "$(cs_verify_get VERIFY_ENGINE_INSTALLED)" "$(cs_verify_get VERIFY_ENGINE_ACTIVE)" \
    "$(cs_verify_get VERIFY_ENGINE_AGSL)" "$(cs_verify_get VERIFY_ENGINE_LOD)" \
    "$(cs_verify_get VERIFY_ENGINE_HOOKS)" "$(cs_verify_get VERIFY_ENGINE_VIEWS)" \
    "$(cs_verify_get VERIFY_ENGINE_TOASTS)" "$(cs_verify_get VERIFY_ENGINE_RECENTS)" \
    "$(cs_verify_get VERIFY_ENGINE_FLOWS)"
  printf 'XML Patcher: status=%s mount=%s tags=%s source=%s\n' \
    "$(cs_state_get XML_STATUS)" "$(cs_verify_get VERIFY_XML_MOUNT)" \
    "$(cs_state_get XML_PATCHED_TAGS)" "$(cs_state_get XML_SOURCE)"
  printf 'RRO Overlays: status=%s active=%s/%s | Video Depth: %s\n' \
    "$(cs_state_get RRO_STATUS)" "$(cs_verify_get VERIFY_RRO_ACTIVE)" \
    "$(cs_verify_get VERIFY_RRO_TOTAL)" "$(cs_verify_get VERIFY_FEAT_VIDEO_DEPTH)"
  printf '\n--- Per-Feature Verification ---\n'
  printf 'FEAT_LUMINOUS_GLASS=%s (%s)\n' "$CFG_FEAT_LUMINOUS_GLASS" "$(cs_verify_get VERIFY_FEAT_LUMINOUS_GLASS)"
  printf 'FEAT_LUMINOUS_TILT=%s (%s)\n' "$CFG_FEAT_LUMINOUS_TILT" "$(cs_verify_get VERIFY_FEAT_LUMINOUS_TILT)"
  printf 'FEAT_LIVING_FLOW=%s (%s)\n' "$CFG_FEAT_LIVING_FLOW" "$(cs_verify_get VERIFY_FEAT_LIVING_FLOW)"
  printf 'FEAT_SURGICAL_GUARD=%s (%s)\n' "$CFG_FEAT_SURGICAL_GUARD" "$(cs_verify_get VERIFY_FEAT_SURGICAL_GUARD)"
  printf 'FEAT_THERMAL_LOD=%s (%s)\n' "$CFG_FEAT_THERMAL_LOD" "$(cs_verify_get VERIFY_FEAT_THERMAL_LOD)"
  printf 'FEAT_BLUR=%s (%s)\n' "$CFG_FEAT_BLUR" "$(cs_verify_get VERIFY_FEAT_BLUR)"
  printf 'FEAT_ANIMATIONS=%s (%s)\n' "$CFG_FEAT_ANIMATIONS" "$(cs_verify_get VERIFY_FEAT_ANIMATIONS)"
  printf 'FEAT_XML_PATCHER=%s (%s)\n' "$CFG_FEAT_XML_PATCHER" "$(cs_verify_get VERIFY_FEAT_XML_PATCHER)"
  printf 'FEAT_RRO_OVERLAYS=%s (%s)\n' "$CFG_FEAT_RRO_OVERLAYS" "$(cs_verify_get VERIFY_FEAT_RRO_OVERLAYS)"
  printf 'FEAT_VIDEO_DEPTH=%s (%s)\n' "$CFG_FEAT_VIDEO_DEPTH" "$(cs_verify_get VERIFY_FEAT_VIDEO_DEPTH)"
  printf 'FEAT_MULTITASK=%s (%s)\n' "$CFG_FEAT_MULTITASK" "$(cs_verify_get VERIFY_FEAT_MULTITASK)"
  printf 'FEAT_DISPLAY_HZ=%s (%s)\n' "$CFG_FEAT_DISPLAY_HZ" "$(cs_verify_get VERIFY_FEAT_DISPLAY_HZ)"
  printf 'FEAT_COLOR_EXPERT=%s (%s)\n' "$CFG_FEAT_COLOR_EXPERT" "$(cs_verify_get VERIFY_FEAT_COLOR_EXPERT)"
  printf 'FEAT_GALLERY_PRO=%s (%s)\n' "$CFG_FEAT_GALLERY_PRO" "$(cs_verify_get VERIFY_FEAT_GALLERY_PRO)"
  printf 'FEAT_AOD_UNLOCK=%s (%s)\n' "$CFG_FEAT_AOD_UNLOCK" "$(cs_verify_get VERIFY_FEAT_AOD_UNLOCK)"
  if [ -s "$CS_OVERRIDDEN_PROPS_FILE" ]; then
    printf '\n--- Overridden Props ---\n'
    cat "$CS_OVERRIDDEN_PROPS_FILE"
  fi
  if [ -r "$CS_LOG_FILE" ]; then
    printf '\n--- Recent Logs ---\n'
    tail -n 15 "$CS_LOG_FILE" 2>/dev/null || true
  fi
}

cs_cmd_reset_safemode() {
  cs_watchdog_init_dir || return 1
  rm -f "$MODDIR/disable"
  cs_write_strikes "0"
  cs_sync_rro_for_next_boot || true
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
  preset)
    cs_cmd_preset "${2:-}"
    ;;
  hot-sync)
    cs_cmd_hot_sync
    ;;
  install-engine)
    cs_cmd_install_engine
    ;;
  diag-report)
    cs_cmd_diag_report
    ;;
  reset-safemode)
    cs_cmd_reset_safemode
    ;;
  *)
    printf 'Usage: %s {status|set <KEY> <VALUE>|preset <stock-safe|balanced|flagship-max>|hot-sync|install-engine|diag-report|reset-safemode}\n' "$0" >&2
    exit 1
    ;;
esac
