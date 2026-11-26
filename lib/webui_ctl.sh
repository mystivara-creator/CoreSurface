#!/system/bin/sh
# CoreSurface - Lightweight WebUI Control Bridge (called via absolute path by webroot/app.js)
# Supports: status | tier <auto|low|balanced_pro|flagship> | set <KEY> <VAL>
#           | preset <stock-safe|balanced|flagship-max> | hot-sync | install-engine
#           | diag-report | reset-safemode

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MODDIR=${CORESURFACE_MODDIR:-$(dirname -- "$SCRIPT_DIR")}

# shellcheck source=lib/detect.sh
. "$MODDIR/lib/detect.sh"
# shellcheck source=lib/watchdog.sh
. "$MODDIR/lib/watchdog.sh"
# shellcheck source=lib/engine_ctl.sh
. "$MODDIR/lib/engine_ctl.sh"
# shellcheck source=lib/rro.sh
. "$MODDIR/lib/rro.sh"
# shellcheck source=lib/props.sh
. "$MODDIR/lib/props.sh"
# shellcheck source=lib/settings_tx.sh
. "$MODDIR/lib/settings_tx.sh"
# shellcheck source=lib/verifier.sh
. "$MODDIR/lib/verifier.sh"
# shellcheck source=lib/os_bug_logic.sh
. "$MODDIR/lib/os_bug_logic.sh"

CS_CONFIG_FILE="$CS_STATE_DIR/config.prop"
CS_COREFLOW_DIR=${CORESURFACE_COREFLOW_DIR:-/data/adb/modules/cfae_framework}
CS_LOCK_DIR="$CS_STATE_DIR/.ctl.lock"

cs_ctl_unlock() {
  rm -rf "$CS_LOCK_DIR" 2>/dev/null || true
}

cs_ctl_lock() {
  cs_watchdog_init_dir || return 1
  _cs_lk_tries=0
  while ! mkdir "$CS_LOCK_DIR" 2>/dev/null; do
    if [ -r "$CS_LOCK_DIR/pid" ]; then
      _cs_lk_pid=$(tr -d ' \t\r\n' < "$CS_LOCK_DIR/pid" 2>/dev/null || true)
      if [ -n "$_cs_lk_pid" ] && ! kill -0 "$_cs_lk_pid" 2>/dev/null; then
        rm -rf "$CS_LOCK_DIR" 2>/dev/null || true
        continue
      fi
    fi
    _cs_lk_tries=$((_cs_lk_tries + 1))
    if [ "$_cs_lk_tries" -ge 20 ]; then
      rm -rf "$CS_LOCK_DIR" 2>/dev/null || true
      mkdir "$CS_LOCK_DIR" 2>/dev/null || true
      break
    fi
    sleep 1 2>/dev/null || true
  done
  printf '%s\n' "$$" > "$CS_LOCK_DIR/pid" 2>/dev/null || true
  trap 'cs_ctl_unlock' EXIT INT TERM
}

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

cs_clear_legacy_overrides() {
  [ -r "$CS_CONFIG_FILE" ] || return 0
  _cs_tmp="$CS_CONFIG_FILE.tmp.$$"
  awk -F '=' '
    $1 != "FEAT_BLUR" && $1 != "FEAT_ANIMATIONS" && $1 != "FEAT_XML_PATCHER" &&
    $1 != "FEAT_RRO_OVERLAYS" && $1 != "FEAT_VIDEO_DEPTH" && $1 != "FEAT_MULTITASK" &&
    $1 != "FEAT_DISPLAY_HZ" && $1 != "FEAT_COLOR_EXPERT" &&
    $1 != "FEAT_FLAGSHIP_AUDIO" && $1 != "FEAT_FLAGSHIP_SUITE" { print $0 }
  ' "$CS_CONFIG_FILE" > "$_cs_tmp"
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

  # Single-pass pure-POSIX read of state.prop (0 awk forks)
  _cs_wd_status="" _cs_wd_reason="" _cs_pending_keys=""
  _cs_xml_status="" _cs_xml_source="" _cs_xml_tags=""
  _cs_rro_status="" _cs_rro_staged=""
  if [ -r "$CS_STATE_FILE" ]; then
    while IFS='=' read -r _cs_sk _cs_sv || [ -n "$_cs_sk" ]; do
      case "$_cs_sk" in
        WATCHDOG_STATUS)  _cs_wd_status="$_cs_sv" ;;
        WATCHDOG_REASON)  _cs_wd_reason="$_cs_sv" ;;
        PENDING_KEYS)     _cs_pending_keys="$_cs_sv" ;;
        XML_STATUS)       _cs_xml_status="$_cs_sv" ;;
        XML_SOURCE)       _cs_xml_source="$_cs_sv" ;;
        XML_PATCHED_TAGS) _cs_xml_tags="$_cs_sv" ;;
        RRO_STATUS)       _cs_rro_status="$_cs_sv" ;;
        RRO_STAGED_COUNT) _cs_rro_staged="$_cs_sv" ;;
      esac
    done < "$CS_STATE_FILE"
  fi

  _cs_strikes=$(cs_read_strikes)
  _cs_cf_guard=$(cs_detect_coreflow_guard)
  _cs_disabled="0"
  if [ -f "$MODDIR/disable" ]; then
    _cs_disabled="1"
    if [ -z "$_cs_wd_status" ] || [ "$_cs_wd_status" = "healthy" ]; then
      _cs_wd_status="safe_mode_disabled"
    fi
  fi

  # Single-pass pure-POSIX read of verify.state (0 awk forks instead of 32)
  _v_ei="" _v_ea="" _v_em="" _v_emo="" _v_ehz="" _v_elod="" _v_ehk="" _v_ebg=""
  _v_eng="" _v_efh="" _v_eag="" _v_esp="" _v_ecv="" _v_ent="" _v_enr="" _v_ect=""
  _v_fmp="" _v_fsg="" _v_faod="" _v_faud="" _v_fsu="" _v_fbl="" _v_fce=""
  _v_xmlm="" _v_rroa="" _v_rrot="" _v_ptot="" _v_pmat="" _v_fver="" _v_fev="" _v_pct=""
  if [ -r "$CS_VERIFY_FILE" ]; then
    while IFS='=' read -r _cs_vk _cs_vv || [ -n "$_cs_vk" ]; do
      case "$_cs_vk" in
        VERIFY_ENGINE_INSTALLED)    _v_ei="$_cs_vv" ;;
        VERIFY_ENGINE_ACTIVE)       _v_ea="$_cs_vv" ;;
        VERIFY_ENGINE_MODE)         _v_em="$_cs_vv" ;;
        VERIFY_ENGINE_MOTION)       _v_emo="$_cs_vv" ;;
        VERIFY_ENGINE_HZ)           _v_ehz="$_cs_vv" ;;
        VERIFY_ENGINE_LOD)          _v_elod="$_cs_vv" ;;
        VERIFY_ENGINE_HOOKS)        _v_ehk="$_cs_vv" ;;
        VERIFY_ENGINE_BUGS)         _v_ebg="$_cs_vv" ;;
        VERIFY_ENGINE_NATIVE_GATES) _v_eng="$_cs_vv" ;;
        VERIFY_ENGINE_FOLME_HOOKS)  _v_efh="$_cs_vv" ;;
        VERIFY_ENGINE_AOD_GATES)    _v_eag="$_cs_vv" ;;
        VERIFY_ENGINE_SPRINGS)      _v_esp="$_cs_vv" ;;
        VERIFY_ENGINE_CURVES)       _v_ecv="$_cs_vv" ;;
        VERIFY_ENGINE_TOASTS)       _v_ent="$_cs_vv" ;;
        VERIFY_ENGINE_RECENTS)      _v_enr="$_cs_vv" ;;
        VERIFY_ENGINE_CIRCUITS)     _v_ect="$_cs_vv" ;;
        VERIFY_FEAT_MOTION_PROFILE) _v_fmp="$_cs_vv" ;;
        VERIFY_FEAT_SURGICAL_GUARD) _v_fsg="$_cs_vv" ;;
        VERIFY_FEAT_AOD_UNLOCK)     _v_faod="$_cs_vv" ;;
        VERIFY_FEAT_FLAGSHIP_AUDIO) _v_faud="$_cs_vv" ;;
        VERIFY_FEAT_FLAGSHIP_SUITE) _v_fsu="$_cs_vv" ;;
        VERIFY_FEAT_BLUR)           _v_fbl="$_cs_vv" ;;
        VERIFY_FEAT_COLOR_EXPERT)   _v_fce="$_cs_vv" ;;
        VERIFY_XML_MOUNT)           _v_xmlm="$_cs_vv" ;;
        VERIFY_RRO_ACTIVE)          _v_rroa="$_cs_vv" ;;
        VERIFY_RRO_TOTAL)           _v_rrot="$_cs_vv" ;;
        VERIFY_PROPS_TOTAL)         _v_ptot="$_cs_vv" ;;
        VERIFY_PROPS_MATCHED)       _v_pmat="$_cs_vv" ;;
        VERIFY_FEAT_VERIFIED)       _v_fver="$_cs_vv" ;;
        VERIFY_FEAT_EVALUATED)      _v_fev="$_cs_vv" ;;
        COMPAT_SCORE_PCT)           _v_pct="$_cs_vv" ;;
      esac
    done < "$CS_VERIFY_FILE"
  fi

  # Single-pass pure-POSIX read of os_bugs.state
  _b_det="" _b_mit="" _b_csv=""
  if [ -r "$CS_OS_BUGS_FILE" ]; then
    while IFS='=' read -r _cs_bk _cs_bv || [ -n "$_cs_bk" ]; do
      case "$_cs_bk" in
        OS_BUGS_DETECTED)  _b_det="$_cs_bv" ;;
        OS_BUGS_MITIGATED) _b_mit="$_cs_bv" ;;
        OS_BUGS_CSV)       _b_csv="$_cs_bv" ;;
      esac
    done < "$CS_OS_BUGS_FILE"
  fi

  printf 'module_version=%s\n' "v1.3.0"
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
  printf 'detected_tier=%s\n' "$CS_DETECTED_TIER"
  printf 'detected_tier_label=%s\n' "$CS_DETECTED_TIER_LABEL"
  printf 'cfg_tier_mode=%s\n' "$CFG_TIER_MODE"
  printf 'eff_tier=%s\n' "$CS_EFF_TIER"
  printf 'eff_tier_label=%s\n' "$CS_EFF_TIER_LABEL"
  printf 'coreflow_guard=%s\n' "$_cs_cf_guard"
  printf 'pending_keys=%s\n' "${_cs_pending_keys:-}"

  printf 'cfg_feat_motion_profile=%s\n' "$CFG_FEAT_MOTION_PROFILE"
  printf 'cfg_feat_surgical_guard=%s\n' "$CFG_FEAT_SURGICAL_GUARD"
  printf 'cfg_feat_aod_unlock=%s\n' "$CFG_FEAT_AOD_UNLOCK"
  printf 'cfg_feat_flagship_audio=%s\n' "$CFG_FEAT_FLAGSHIP_AUDIO"
  printf 'cfg_feat_flagship_suite=%s\n' "$CFG_FEAT_FLAGSHIP_SUITE"
  printf 'eff_feat_motion_profile=%s\n' "$EFF_FEAT_MOTION_PROFILE"
  printf 'eff_feat_blur=%s\n' "$EFF_FEAT_BLUR"
  printf 'eff_feat_adv_textures=%s\n' "$EFF_FEAT_ADV_TEXTURES"
  printf 'eff_feat_color_expert=%s\n' "$EFF_FEAT_COLOR_EXPERT"
  printf 'stock_has_expert_color=%s\n' "${CS_STOCK_HAS_EXPERT_COLOR:-0}"
  printf 'eff_feat_aod_unlock=%s\n' "$EFF_FEAT_AOD_UNLOCK"
  printf 'eff_feat_flagship_audio=%s\n' "$EFF_FEAT_FLAGSHIP_AUDIO"
  printf 'eff_feat_flagship_suite=%s\n' "$EFF_FEAT_FLAGSHIP_SUITE"

  printf 'xml_status=%s\n' "${_cs_xml_status:-skipped}"
  printf 'xml_source=%s\n' "${_cs_xml_source:-none}"
  printf 'xml_patched_tags=%s\n' "${_cs_xml_tags:-0}"
  printf 'rro_status=%s\n' "${_cs_rro_status:-skipped}"
  printf 'rro_staged_count=%s\n' "${_cs_rro_staged:-0}"

  printf 'verify_engine_installed=%s\n' "$_v_ei"
  printf 'verify_engine_active=%s\n' "$_v_ea"
  printf 'verify_engine_mode=%s\n' "$_v_em"
  printf 'verify_engine_motion=%s\n' "$_v_emo"
  printf 'verify_engine_hz=%s\n' "$_v_ehz"
  printf 'verify_engine_lod=%s\n' "$_v_elod"
  printf 'verify_engine_hooks=%s\n' "$_v_ehk"
  printf 'verify_engine_bugs=%s\n' "$_v_ebg"
  printf 'verify_engine_native_gates=%s\n' "$_v_eng"
  printf 'verify_engine_folme_hooks=%s\n' "$_v_efh"
  printf 'verify_engine_aod_gates=%s\n' "$_v_eag"
  printf 'verify_engine_springs=%s\n' "$_v_esp"
  printf 'verify_engine_curves=%s\n' "$_v_ecv"
  printf 'verify_engine_toasts=%s\n' "$_v_ent"
  printf 'verify_engine_recents=%s\n' "$_v_enr"
  printf 'verify_engine_circuits=%s\n' "$_v_ect"

  printf 'os_bugs_detected=%s\n' "$_b_det"
  printf 'os_bugs_mitigated=%s\n' "$_b_mit"
  printf 'os_bugs_csv=%s\n' "$_b_csv"

  printf 'verify_feat_motion_profile=%s\n' "$_v_fmp"
  printf 'verify_feat_surgical_guard=%s\n' "$_v_fsg"
  printf 'verify_feat_aod_unlock=%s\n' "$_v_faod"
  printf 'verify_feat_flagship_audio=%s\n' "$_v_faud"
  printf 'verify_feat_flagship_suite=%s\n' "$_v_fsu"
  printf 'verify_feat_blur=%s\n' "$_v_fbl"
  printf 'verify_feat_color_expert=%s\n' "$_v_fce"
  printf 'verify_xml_mount=%s\n' "$_v_xmlm"
  printf 'verify_rro_active=%s\n' "$_v_rroa"
  printf 'verify_rro_total=%s\n' "$_v_rrot"
  printf 'verify_props_total=%s\n' "$_v_ptot"
  printf 'verify_props_matched=%s\n' "$_v_pmat"
  printf 'verify_feat_verified=%s\n' "$_v_fver"
  printf 'verify_feat_evaluated=%s\n' "$_v_fev"
  printf 'compat_score_pct=%s\n' "$_v_pct"

  printf 'log_start\n'
  if [ -r "$CS_LOG_FILE" ]; then
    tail -n 25 "$CS_LOG_FILE" 2>/dev/null || true
  fi
  printf 'log_end\n'
}

cs_cmd_tier() {
  _cs_tm=$1
  case "$_cs_tm" in
    auto|low|balanced_pro|flagship) ;;
    *)
      printf 'Invalid tier mode: %s (expected auto|low|balanced_pro|flagship)\n' "$_cs_tm" >&2
      return 1
      ;;
  esac

  cs_ensure_config || return 1
  cs_clear_legacy_overrides
  cs_write_config_key "CS_TIER_MODE" "$_cs_tm"

  # Pick a matching smooth default motion curve when switching tier
  case "$_cs_tm" in
    flagship) cs_write_config_key "FEAT_MOTION_PROFILE" "snappy" ;;
    *)        cs_write_config_key "FEAT_MOTION_PROFILE" "fluid" ;;
  esac

  cs_sync_rro_for_next_boot || true
  cs_reassert_computility_props || true
  cs_sync_engine_live_prop || true
  cs_settings_sync_all || true
  cs_verifier_run || true
  cs_add_pending_key "CS_TIER_MODE"
  cs_log "WebUI set CS_TIER_MODE=${_cs_tm} (eff=${CS_EFF_TIER}; Motion & Computility live-synced, reboot for early-boot props/XML/RRO)."
  printf 'Tier mode "%s" saved (Motion & Computility active LIVE; reboot once for props/XML/RRO).\n' "$_cs_tm"
}

cs_cmd_set() {
  _cs_set_k=$1
  _cs_set_v=$2
  _cs_is_live="0"

  case "$_cs_set_k" in
    CS_TIER_MODE)
      cs_cmd_tier "$_cs_set_v"
      return $?
      ;;
    FEAT_MOTION_PROFILE)
      _cs_is_live="1"
      case "$_cs_set_v" in
        snappy|fluid|bouncy|0) ;;
        coloros|silk) _cs_set_v="snappy" ;;
        hyperos4)     _cs_set_v="fluid" ;;
        ios)          _cs_set_v="bouncy" ;;
        *)
          printf 'Invalid value for %s: %s (expected snappy|fluid|bouncy|0)\n' "$_cs_set_k" "$_cs_set_v" >&2
          return 1
          ;;
      esac
      ;;
    FEAT_NATIVE_TIER|FEAT_SURGICAL_GUARD|FEAT_THERMAL_LOD)
      _cs_is_live="1"
      case "$_cs_set_v" in
        auto|1|0) ;;
        *)
          printf 'Invalid value for %s: %s (expected auto|1|0)\n' "$_cs_set_k" "$_cs_set_v" >&2
          return 1
          ;;
      esac
      ;;
    FEAT_AOD_UNLOCK|FEAT_FLAGSHIP_AUDIO|FEAT_FLAGSHIP_SUITE|FEAT_BLUR|FEAT_ANIMATIONS|FEAT_XML_PATCHER|FEAT_RRO_OVERLAYS|FEAT_VIDEO_DEPTH|FEAT_MULTITASK|FEAT_DISPLAY_HZ|FEAT_COLOR_EXPERT)
      case "$_cs_set_v" in
        auto|1|0) ;;
        *)
          printf 'Invalid value for %s: %s (expected auto|1|0)\n' "$_cs_set_k" "$_cs_set_v" >&2
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
    cs_sync_engine_live_prop || true
    cs_settings_sync_engine_ipc || true
    cs_verifier_run || true
    cs_log "WebUI live-updated ${_cs_set_k}=${_cs_set_v} (instant reload via debug.coresurface.cfg, 0 reboot)."
    printf 'LIVE Applied %s=%s (active immediately without reboot!).\n' "$_cs_set_k" "$_cs_set_v"
    return 0
  fi

  cs_sync_rro_for_next_boot || true
  if [ "$_cs_set_k" = "FEAT_AOD_UNLOCK" ]; then
    cs_sync_engine_live_prop || true
    cs_settings_sync_all || true
  fi
  cs_add_pending_key "$_cs_set_k"
  cs_log "WebUI updated ${_cs_set_k}=${_cs_set_v} (reboot required for early-boot props/XML/RRO)."
  printf 'Saved %s=%s. Reboot once to apply RRO/XML/props.\n' "$_cs_set_k" "$_cs_set_v"
}

cs_cmd_preset() {
  case "${1:-}" in
    stock-safe|low)        cs_cmd_tier "low" ;;
    balanced|balanced_pro) cs_cmd_tier "balanced_pro" ;;
    flagship-max|flagship) cs_cmd_tier "flagship" ;;
    auto)                  cs_cmd_tier "auto" ;;
    *)
      printf 'Unknown preset: %s (expected auto|low|balanced_pro|flagship)\n' "${1:-}" >&2
      return 1
      ;;
  esac
}

cs_cmd_hot_sync() {
  cs_ensure_config || return 1
  cs_detect_rom || true
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_features
  cs_reassert_computility_props || true
  cs_sync_engine_live_prop || true
  cs_rro_enable_staged || true
  cs_settings_sync_all || true
  cs_os_bug_scan "late" "$MODDIR" || true
  cs_verifier_run || true
  cs_log "WebUI triggered instant Motion Engine + Computility + RRO + settings hot-sync & re-verification."
  printf 'Hot-Sync & re-verification completed without reboot.\n'
}

cs_cmd_install_engine() {
  _cs_apk="$CS_STATE_DIR/CoreSurfaceEngine.apk"
  [ -r "$_cs_apk" ] || _cs_apk="$MODDIR/engine/CoreSurfaceEngine.apk"
  if [ ! -r "$_cs_apk" ]; then
    printf 'CoreSurfaceEngine.apk not found inside module.\n' >&2
    return 1
  fi
  if ! command -v pm >/dev/null 2>&1; then
    printf 'Android pm command is unavailable.\n' >&2
    return 1
  fi

  if cs_pm_install_apk "$_cs_apk"; then
    cs_engine_write_stamp "$_cs_apk"
    cs_verifier_run || true
    cs_log "WebUI installed/updated CoreSurfaceEngine.apk."
    printf 'CoreSurfaceEngine.apk installed! Enable once in LSPosed (Recommended scope is auto-pinned at top).\n'
    return 0
  fi

  printf 'Failed to install APK (%s). Install manually from %s\n' "${CS_PM_LAST_OUT:-unknown}" "$_cs_apk" >&2
  return 1
}

cs_cmd_diag_report() {
  cs_ensure_config || true
  cs_detect_rom || true
  cs_detect_ram_tier
  cs_load_config "$CS_CONFIG_FILE"
  cs_resolve_features

  printf '=== CoreSurface v1.3.0 Flagship Motion Diagnostic Report ===\n'
  printf 'ROM: %s (%s) | HyperOS Major: %s | Android SDK: %s\n' \
    "$CS_ROM_FAMILY" "${CS_ROM_VERSION:-Unknown}" "$CS_HYPEROS_MAJOR" "$CS_ANDROID_SDK"
  printf 'RAM: %s MB (%s) | Tier: %s (cfg=%s, detected=%s) | CoreFlow Guard: %s\n' \
    "$CS_RAM_MB" "$CS_RAM_TIER_LABEL" "$CS_EFF_TIER" "$CFG_TIER_MODE" "$CS_DETECTED_TIER" "$(cs_detect_coreflow_guard)"
  printf 'Watchdog: %s (reason=%s, strikes=%s/2)\n' \
    "$(cs_state_get WATCHDOG_STATUS)" "$(cs_state_get WATCHDOG_REASON)" "$(cs_read_strikes)"
  printf 'Compatibility Score: %s%% (%s/%s features verified; props %s/%s matched)\n' \
    "$(cs_verify_get COMPAT_SCORE_PCT)" \
    "$(cs_verify_get VERIFY_FEAT_VERIFIED)" "$(cs_verify_get VERIFY_FEAT_EVALUATED)" \
    "$(cs_verify_get VERIFY_PROPS_MATCHED)" "$(cs_verify_get VERIFY_PROPS_TOTAL)"
  printf 'Motion Engine: installed=%s active=%s profile=%s hz=%s lod=%s hooks=%s gates=%s folme=%s aod_gates=%s springs=%s curves=%s toasts=%s recents=%s circuits=%s\n' \
    "$(cs_verify_get VERIFY_ENGINE_INSTALLED)" "$(cs_verify_get VERIFY_ENGINE_ACTIVE)" \
    "$(cs_verify_get VERIFY_ENGINE_MOTION)" "$(cs_verify_get VERIFY_ENGINE_HZ)" \
    "$(cs_verify_get VERIFY_ENGINE_LOD)" "$(cs_verify_get VERIFY_ENGINE_HOOKS)" \
    "$(cs_verify_get VERIFY_ENGINE_NATIVE_GATES)" "$(cs_verify_get VERIFY_ENGINE_FOLME_HOOKS)" \
    "$(cs_verify_get VERIFY_ENGINE_AOD_GATES)" "$(cs_verify_get VERIFY_ENGINE_SPRINGS)" \
    "$(cs_verify_get VERIFY_ENGINE_CURVES)" "$(cs_verify_get VERIFY_ENGINE_TOASTS)" \
    "$(cs_verify_get VERIFY_ENGINE_RECENTS)" "$(cs_verify_get VERIFY_ENGINE_CIRCUITS)"
  printf 'OS Bug Logic: detected=%s mitigated=%s list=%s runtime=%s\n' \
    "$(cs_telem_get "$CS_OS_BUGS_FILE" OS_BUGS_DETECTED)" \
    "$(cs_telem_get "$CS_OS_BUGS_FILE" OS_BUGS_MITIGATED)" \
    "$(cs_telem_get "$CS_OS_BUGS_FILE" OS_BUGS_CSV)" \
    "$(cs_verify_get VERIFY_ENGINE_BUGS)"
  printf 'XML Patcher: status=%s mount=%s tags=%s source=%s\n' \
    "$(cs_state_get XML_STATUS)" "$(cs_verify_get VERIFY_XML_MOUNT)" \
    "$(cs_state_get XML_PATCHED_TAGS)" "$(cs_state_get XML_SOURCE)"
  printf 'RRO Overlays: status=%s active=%s/%s | Custom Color Expert: %s | AOD Unlock: %s\n' \
    "$(cs_state_get RRO_STATUS)" "$(cs_verify_get VERIFY_RRO_ACTIVE)" \
    "$(cs_verify_get VERIFY_RRO_TOTAL)" "$(cs_verify_get VERIFY_FEAT_COLOR_EXPERT)" \
    "$(cs_verify_get VERIFY_FEAT_AOD_UNLOCK)"
  printf 'Flagship Porting: Audio & Speaker=%s | Porting Suite=%s\n' \
    "$(cs_verify_get VERIFY_FEAT_FLAGSHIP_AUDIO)" \
    "$(cs_verify_get VERIFY_FEAT_FLAGSHIP_SUITE)"
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
  status)         cs_cmd_status ;;
  tier)           cs_ctl_lock && cs_cmd_tier "${2:-}" ;;
  set)            cs_ctl_lock && cs_cmd_set "${2:-}" "${3:-}" ;;
  preset)         cs_ctl_lock && cs_cmd_preset "${2:-}" ;;
  hot-sync)       cs_ctl_lock && cs_cmd_hot_sync ;;
  install-engine) cs_ctl_lock && cs_cmd_install_engine ;;
  diag-report)    cs_cmd_diag_report ;;
  reset-safemode) cs_ctl_lock && cs_cmd_reset_safemode ;;
  *)
    printf 'Usage: %s {status|tier <auto|low|balanced_pro|flagship>|set <KEY> <VALUE>|preset <...>|hot-sync|install-engine|diag-report|reset-safemode}\n' "$0" >&2
    exit 1
    ;;
esac
