#!/system/bin/sh
# CoreSurface - Layer 1 (ROM & SDK Gate) & Layer 2 (Dynamic Hardware & 4-Tier Classification)
# Pure POSIX sh. Zero hardcoded device codenames.
# Includes Native Flagship Passthrough (motion_only) & Never-Downgrade intelligence.

cs_getprop() {
  _cs_gp_key=$1
  if command -v getprop >/dev/null 2>&1; then
    getprop "$_cs_gp_key" 2>/dev/null || true
  fi
}

cs_is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Detect ROM family, version string, HyperOS major version, and Android SDK.
# Sets: CS_ROM_FAMILY, CS_ROM_VERSION, CS_HYPEROS_MAJOR, CS_ANDROID_SDK
cs_detect_rom() {
  CS_ROM_FAMILY="unsupported"
  CS_ROM_VERSION=""
  CS_HYPEROS_MAJOR="0"
  CS_ANDROID_SDK="0"

  _cs_hos_ver=$(cs_getprop "ro.mi.os.version.name")
  _cs_miui_ver=$(cs_getprop "ro.miui.ui.version.name")
  _cs_sdk=$(cs_getprop "ro.build.version.sdk")

  if cs_is_uint "$_cs_sdk"; then
    CS_ANDROID_SDK="$_cs_sdk"
  fi

  export CS_ROM_FAMILY CS_ROM_VERSION CS_HYPEROS_MAJOR CS_ANDROID_SDK

  if [ -n "$_cs_hos_ver" ]; then
    CS_ROM_FAMILY="hyperos"
    CS_ROM_VERSION="$_cs_hos_ver"
    _cs_major=$(printf '%s\n' "$_cs_hos_ver" | sed -n 's/^[^0-9]*\([0-9][0-9]*\).*/\1/p')
    if cs_is_uint "$_cs_major"; then
      CS_HYPEROS_MAJOR="$_cs_major"
    else
      _cs_hos_code=$(cs_getprop "ro.mi.os.version.code")
      if cs_is_uint "$_cs_hos_code"; then
        CS_HYPEROS_MAJOR="$_cs_hos_code"
      fi
    fi
    return 0
  fi

  if [ -n "$_cs_miui_ver" ]; then
    CS_ROM_FAMILY="miui"
    CS_ROM_VERSION="$_cs_miui_ver"
    return 0
  fi

  return 1
}

# Inspect stock unmodified device_features XML & ro.miui.device_level (read-only)
# so CoreSurface can detect genuine Native Flagships (already unlocked from factory)
# and never downgrade stock factory capabilities.
# Snapshots immutable factory values in $CS_STATE_DIR/stock_caps.prop keyed by
# build fingerprint + device + ROM version so late-boot (service.sh / webui_ctl.sh)
# and soft-reboots NEVER mistake CoreSurface's own flagship overrides for stock!
# Sets: CS_STOCK_DEVICE_LEVEL, CS_STOCK_HAS_BLUR, CS_STOCK_HAS_EXPERT_COLOR,
#       CS_STOCK_BLURS_EXPENSIVE, CS_STOCK_LOW_RAM, CS_STOCK_DEVICE_LEVEL_LIST
cs_probe_stock_capabilities() {
  CS_STOCK_DEVICE_LEVEL="0"
  CS_STOCK_HAS_BLUR="0"
  CS_STOCK_HAS_EXPERT_COLOR="0"
  CS_STOCK_BLURS_EXPENSIVE="0"
  CS_STOCK_LOW_RAM="0"
  CS_STOCK_DEVICE_LEVEL_LIST=""
  CS_STOCK_CPU_LEVEL="0"
  CS_STOCK_GPU_LEVEL="0"
  CS_STOCK_ADV_VISUAL_RELEASE="0"
  export CS_STOCK_DEVICE_LEVEL CS_STOCK_HAS_BLUR CS_STOCK_HAS_EXPERT_COLOR \
    CS_STOCK_BLURS_EXPENSIVE CS_STOCK_LOW_RAM CS_STOCK_DEVICE_LEVEL_LIST \
    CS_STOCK_CPU_LEVEL CS_STOCK_GPU_LEVEL CS_STOCK_ADV_VISUAL_RELEASE

  _cs_sdir=${CS_STATE_DIR:-${CORESURFACE_STATE_DIR:-/data/adb/coresurface}}
  _cs_snap_file="${_cs_sdir}/stock_caps.prop"
  _cs_fp=$(cs_getprop "ro.build.fingerprint")
  _cs_dev=$(cs_getprop "ro.product.device")
  _cs_snap_id="${_cs_fp}|${_cs_dev}|${CS_ROM_VERSION:-}"

  # Reuse immutable stock snapshot if it matches current ROM fingerprint/device/version
  if [ "${CS_FORCE_FRESH_STOCK_PROBE:-0}" != "1" ] && [ -r "$_cs_snap_file" ]; then
    _cs_saved_id=$(awk -F '=' '$1 == "SNAP_ID" { sub(/^[^=]*=/, ""); print; exit }' "$_cs_snap_file" 2>/dev/null | tr -d '\r')
    if [ "$_cs_saved_id" = "$_cs_snap_id" ]; then
      while IFS='=' read -r _cs_sk _cs_sv || [ -n "$_cs_sk" ]; do
        _cs_sk=$(printf '%s' "$_cs_sk" | tr -d '\r')
        _cs_sv=$(printf '%s' "$_cs_sv" | tr -d '\r')
        case "$_cs_sk" in
          STOCK_DEVICE_LEVEL) cs_is_uint "$_cs_sv" && CS_STOCK_DEVICE_LEVEL="$_cs_sv" ;;
          STOCK_HAS_BLUR) [ "$_cs_sv" = "1" ] && CS_STOCK_HAS_BLUR="1" ;;
          STOCK_HAS_EXPERT_COLOR) [ "$_cs_sv" = "1" ] && CS_STOCK_HAS_EXPERT_COLOR="1" ;;
          STOCK_BLURS_EXPENSIVE) [ "$_cs_sv" = "1" ] && CS_STOCK_BLURS_EXPENSIVE="1" ;;
          STOCK_LOW_RAM) [ "$_cs_sv" = "1" ] && CS_STOCK_LOW_RAM="1" ;;
          STOCK_DEVICE_LEVEL_LIST) CS_STOCK_DEVICE_LEVEL_LIST="$_cs_sv" ;;
          STOCK_CPU_LEVEL) cs_is_uint "$_cs_sv" && CS_STOCK_CPU_LEVEL="$_cs_sv" ;;
          STOCK_GPU_LEVEL) cs_is_uint "$_cs_sv" && CS_STOCK_GPU_LEVEL="$_cs_sv" ;;
          STOCK_ADV_VISUAL_RELEASE) cs_is_uint "$_cs_sv" && CS_STOCK_ADV_VISUAL_RELEASE="$_cs_sv" ;;
        esac
      done < "$_cs_snap_file"
      return 0
    fi
  fi

  _cs_sp_lvl=$(cs_getprop "ro.miui.device_level")
  if cs_is_uint "$_cs_sp_lvl"; then
    CS_STOCK_DEVICE_LEVEL="$_cs_sp_lvl"
  fi
  _cs_scpu=$(cs_getprop "persist.sys.computility.cpulevel")
  if cs_is_uint "$_cs_scpu"; then
    CS_STOCK_CPU_LEVEL="$_cs_scpu"
  fi
  _cs_sgpu=$(cs_getprop "persist.sys.computility.gpulevel")
  if cs_is_uint "$_cs_sgpu"; then
    CS_STOCK_GPU_LEVEL="$_cs_sgpu"
  fi
  _cs_savr=$(cs_getprop "persist.sys.advanced_visual_release")
  if cs_is_uint "$_cs_savr"; then
    CS_STOCK_ADV_VISUAL_RELEASE="$_cs_savr"
  fi
  if [ "$(cs_getprop "ro.sf.blurs_are_expensive")" = "1" ]; then
    CS_STOCK_BLURS_EXPENSIVE="1"
  fi
  if [ "$(cs_getprop "ro.config.low_ram")" = "true" ]; then
    CS_STOCK_LOW_RAM="1"
  fi
  CS_STOCK_DEVICE_LEVEL_LIST=$(cs_getprop "persist.sys.deviceLevelList")

  _cs_dirs=${CORESURFACE_XML_SEARCH_DIRS:-/mi_ext/product/etc/device_features:/product/etc/device_features:/system/etc/device_features:/vendor/etc/device_features}
  _cs_stock_xml=""

  if [ -n "$_cs_dev" ]; then
    _cs_old_ifs=$IFS
    IFS=':'
    for _cs_dir in $_cs_dirs; do
      IFS=$_cs_old_ifs
      if [ -r "${_cs_dir}/${_cs_dev}.xml" ]; then
        _cs_stock_xml="${_cs_dir}/${_cs_dev}.xml"
        break
      fi
    done
    IFS=$_cs_old_ifs
  fi

  if [ -n "$_cs_stock_xml" ]; then
    _cs_xlvl=$(sed -n 's/.*<integer name="device_level">[[:space:]]*\([0-9][0-9]*\)[[:space:]]*<\/integer>.*/\1/p' "$_cs_stock_xml" 2>/dev/null | head -n 1 || true)
    if cs_is_uint "$_cs_xlvl" && [ "$_cs_xlvl" -gt "$CS_STOCK_DEVICE_LEVEL" ]; then
      CS_STOCK_DEVICE_LEVEL="$_cs_xlvl"
    fi
    if grep -q '<bool name="support_background_blur">[[:space:]]*true[[:space:]]*</bool>' "$_cs_stock_xml" 2>/dev/null; then
      CS_STOCK_HAS_BLUR="1"
    fi
    if grep -q '<bool name="support_display_expert_mode">[[:space:]]*true[[:space:]]*</bool>' "$_cs_stock_xml" 2>/dev/null; then
      CS_STOCK_HAS_EXPERT_COLOR="1"
    fi
  fi

  # Persist immutable factory snapshot when explicitly allowed (early boot / install)
  if [ "${CS_ALLOW_STOCK_SNAPSHOT_WRITE:-0}" = "1" ] && [ -d "$_cs_sdir" ]; then
    _cs_snap_tmp="${_cs_snap_file}.tmp.$$"
    if {
      printf 'SNAP_ID=%s\n' "$_cs_snap_id"
      printf 'STOCK_DEVICE_LEVEL=%s\n' "$CS_STOCK_DEVICE_LEVEL"
      printf 'STOCK_HAS_BLUR=%s\n' "$CS_STOCK_HAS_BLUR"
      printf 'STOCK_HAS_EXPERT_COLOR=%s\n' "$CS_STOCK_HAS_EXPERT_COLOR"
      printf 'STOCK_BLURS_EXPENSIVE=%s\n' "$CS_STOCK_BLURS_EXPENSIVE"
      printf 'STOCK_LOW_RAM=%s\n' "$CS_STOCK_LOW_RAM"
      printf 'STOCK_DEVICE_LEVEL_LIST=%s\n' "$CS_STOCK_DEVICE_LEVEL_LIST"
      printf 'STOCK_CPU_LEVEL=%s\n' "$CS_STOCK_CPU_LEVEL"
      printf 'STOCK_GPU_LEVEL=%s\n' "$CS_STOCK_GPU_LEVEL"
      printf 'STOCK_ADV_VISUAL_RELEASE=%s\n' "$CS_STOCK_ADV_VISUAL_RELEASE"
    } > "$_cs_snap_tmp" 2>/dev/null; then
      mv -f "$_cs_snap_tmp" "$_cs_snap_file" 2>/dev/null || rm -f "$_cs_snap_tmp" 2>/dev/null || true
    else
      rm -f "$_cs_snap_tmp" 2>/dev/null || true
    fi
  fi
}

# Read MemTotal from /proc/meminfo (or CORESURFACE_MEMINFO override) in MB
# and classify hardware class dynamically (distinguishing Entry/Mid Non-Pro,
# Mid-Range Pro/Pro+, High-RAM Enthusiast, and Native Flagship Passthrough
# without hardcoding any device codenames).
# Sets: CS_RAM_MB, CS_RAM_TIER (low | mid | high), CS_RAM_TIER_LABEL,
#       CS_DETECTED_TIER (low | balanced_pro | flagship | motion_only), CS_DETECTED_TIER_LABEL
cs_detect_ram_tier() {
  _cs_meminfo=${CORESURFACE_MEMINFO:-/proc/meminfo}
  CS_RAM_MB="0"
  CS_RAM_TIER="low"
  CS_RAM_TIER_LABEL="< 6 GB"
  CS_DETECTED_TIER="low"
  CS_DETECTED_TIER_LABEL="Lite (Entry / Mid Non-Pro)"
  export CS_RAM_MB CS_RAM_TIER CS_RAM_TIER_LABEL CS_DETECTED_TIER CS_DETECTED_TIER_LABEL

  if [ -r "$_cs_meminfo" ]; then
    _cs_kb=$(awk '/^MemTotal:/ { print $2; exit }' "$_cs_meminfo" 2>/dev/null || true)
    if cs_is_uint "$_cs_kb"; then
      CS_RAM_MB=$((_cs_kb / 1024))
    fi
  fi

  # Physical 6 GB ~5632-6000 MB, 8 GB ~7168-8000 MB, 12 GB+ >= 10240 MB
  if [ "$CS_RAM_MB" -ge 7168 ]; then
    CS_RAM_TIER="high"
    CS_RAM_TIER_LABEL=">= 8 GB"
  elif [ "$CS_RAM_MB" -ge 5632 ]; then
    CS_RAM_TIER="mid"
    CS_RAM_TIER_LABEL="6-7 GB"
  else
    CS_RAM_TIER="low"
    CS_RAM_TIER_LABEL="< 6 GB"
  fi

  cs_probe_stock_capabilities

  _cs_mkt=$(cs_getprop "ro.product.marketname")
  if [ -z "$_cs_mkt" ]; then
    _cs_mkt=$(cs_getprop "ro.product.model")
  fi
  _cs_mkt_lc=$(printf '%s' "$_cs_mkt" | tr '[:upper:]' '[:lower:]')

  # 1. Genuine Native Flagship Passthrough:
  #    Device ALREADY ships with factory device_level >= 3 AND factory background blur.
  #    Do not redundantly overwrite factory flagship Layer 1 props/RRO; run Motion-Only!
  if [ "$CS_STOCK_DEVICE_LEVEL" -ge 3 ] && [ "$CS_STOCK_HAS_BLUR" = "1" ]; then
    CS_DETECTED_TIER="motion_only"
    CS_DETECTED_TIER_LABEL="Native Flagship (Motion-Only Passthrough)"
    return 0
  fi

  # 2. High-RAM Enthusiast / Flagship-Killer (>= 12 GB RAM or Ultra/Fold/Mix without factory unlock)
  if [ "$CS_RAM_MB" -ge 10240 ]; then
    CS_DETECTED_TIER="flagship"
    CS_DETECTED_TIER_LABEL="Max Flagship"
    return 0
  fi

  case "$_cs_mkt_lc" in
    *ultra*|*fold*|*flip*|*mix*)
      if [ "$CS_RAM_MB" -ge 7168 ]; then
        CS_DETECTED_TIER="flagship"
        CS_DETECTED_TIER_LABEL="Max Flagship"
      else
        CS_DETECTED_TIER="balanced_pro"
        CS_DETECTED_TIER_LABEL="Balanced Pro / Pro+"
      fi
      ;;
    *pro*|*turbo*|*gt*)
      if [ "$CS_RAM_MB" -ge 5632 ]; then
        CS_DETECTED_TIER="balanced_pro"
        CS_DETECTED_TIER_LABEL="Balanced Pro / Pro+"
      else
        CS_DETECTED_TIER="low"
        CS_DETECTED_TIER_LABEL="Lite (Entry / Mid Non-Pro)"
      fi
      ;;
    '')
      # Fallback when marketname/model is not exposed: use RAM tier
      if [ "$CS_RAM_MB" -ge 7168 ]; then
        CS_DETECTED_TIER="balanced_pro"
        CS_DETECTED_TIER_LABEL="Balanced Pro / Pro+"
      else
        CS_DETECTED_TIER="low"
        CS_DETECTED_TIER_LABEL="Lite (Entry / Mid Non-Pro)"
      fi
      ;;
    *)
      # Named non-Pro mid-range / entry device (e.g., Redmi Note 15 5G) -> Lite (Blur ON, no Advanced Textures)
      CS_DETECTED_TIER="low"
      CS_DETECTED_TIER_LABEL="Lite (Entry / Mid Non-Pro)"
      ;;
  esac
}

# Load user config safely without executing arbitrary shell code.
cs_load_config() {
  _cs_cfg_file=$1

  CFG_TIER_MODE="auto"
  CFG_FEAT_AOD_UNLOCK="1"

  # Base features default to "auto" (driven cleanly by CS_TIER_MODE unless explicitly overridden)
  CFG_FEAT_BLUR="auto"
  CFG_FEAT_ANIMATIONS="auto"
  CFG_FEAT_XML_PATCHER="auto"
  CFG_FEAT_RRO_OVERLAYS="auto"
  CFG_FEAT_VIDEO_DEPTH="auto"
  CFG_FEAT_MULTITASK="auto"
  CFG_FEAT_DISPLAY_HZ="auto"
  CFG_FEAT_COLOR_EXPERT="1"
  CFG_FEAT_FLAGSHIP_AUDIO="auto"
  CFG_FEAT_FLAGSHIP_SUITE="auto"

  export CFG_TIER_MODE CFG_FEAT_AOD_UNLOCK \
    CFG_FEAT_BLUR CFG_FEAT_ANIMATIONS CFG_FEAT_XML_PATCHER CFG_FEAT_RRO_OVERLAYS \
    CFG_FEAT_VIDEO_DEPTH CFG_FEAT_MULTITASK CFG_FEAT_DISPLAY_HZ CFG_FEAT_COLOR_EXPERT \
    CFG_FEAT_FLAGSHIP_AUDIO CFG_FEAT_FLAGSHIP_SUITE

  [ -r "$_cs_cfg_file" ] || return 0

  while IFS='=' read -r _cs_k _cs_v || [ -n "$_cs_k" ]; do
    _cs_k=$(printf '%s' "$_cs_k" | tr -d '\r')
    _cs_v=$(printf '%s' "$_cs_v" | tr -d '\r')
    case "$_cs_k" in
      ''|'#'*) continue ;;
      CS_TIER_MODE)
        case "$_cs_v" in
          auto|low|balanced_pro|flagship) CFG_TIER_MODE="$_cs_v" ;;
          lite)         CFG_TIER_MODE="low" ;;
          max_flagship) CFG_TIER_MODE="flagship" ;;
        esac
        ;;
      FEAT_AOD_UNLOCK)
        case "$_cs_v" in auto|1|0) CFG_FEAT_AOD_UNLOCK="$_cs_v" ;; esac
        ;;
      FEAT_BLUR)
        case "$_cs_v" in auto|1|0) CFG_FEAT_BLUR="$_cs_v" ;; esac
        ;;
      FEAT_ANIMATIONS)
        case "$_cs_v" in auto|1|0) CFG_FEAT_ANIMATIONS="$_cs_v" ;; esac
        ;;
      FEAT_XML_PATCHER)
        case "$_cs_v" in auto|1|0) CFG_FEAT_XML_PATCHER="$_cs_v" ;; esac
        ;;
      FEAT_RRO_OVERLAYS)
        case "$_cs_v" in auto|1|0) CFG_FEAT_RRO_OVERLAYS="$_cs_v" ;; esac
        ;;
      FEAT_VIDEO_DEPTH)
        case "$_cs_v" in auto|1|0) CFG_FEAT_VIDEO_DEPTH="$_cs_v" ;; esac
        ;;
      FEAT_MULTITASK)
        case "$_cs_v" in auto|1|0) CFG_FEAT_MULTITASK="$_cs_v" ;; esac
        ;;
      FEAT_DISPLAY_HZ)
        case "$_cs_v" in auto|1|0) CFG_FEAT_DISPLAY_HZ="$_cs_v" ;; esac
        ;;
      FEAT_COLOR_EXPERT)
        case "$_cs_v" in auto|1|0) CFG_FEAT_COLOR_EXPERT="$_cs_v" ;; esac
        ;;
      FEAT_FLAGSHIP_AUDIO)
        case "$_cs_v" in auto|1|0) CFG_FEAT_FLAGSHIP_AUDIO="$_cs_v" ;; esac
        ;;
      FEAT_FLAGSHIP_SUITE)
        case "$_cs_v" in auto|1|0) CFG_FEAT_FLAGSHIP_SUITE="$_cs_v" ;; esac
        ;;
    esac
  done < "$_cs_cfg_file"
}

# Resolve effective tier (low | balanced_pro | flagship | motion_only) and per-feature flags.
cs_resolve_features() {
  case "$CFG_TIER_MODE" in
    low)          CS_EFF_TIER="low" ;;
    balanced_pro) CS_EFF_TIER="balanced_pro" ;;
    flagship)     CS_EFF_TIER="flagship" ;;
    *)            CS_EFF_TIER="${CS_DETECTED_TIER:-low}" ;;
  esac

  case "$CS_EFF_TIER" in
    motion_only)  CS_EFF_TIER_LABEL="Native Flagship (Stock Passthrough)" ;;
    flagship)     CS_EFF_TIER_LABEL="Max Flagship" ;;
    balanced_pro) CS_EFF_TIER_LABEL="Balanced Pro / Pro+" ;;
    *)            CS_EFF_TIER_LABEL="Lite (Standard Blur, No Advanced Textures)" ;;
  esac

  EFF_FEAT_AOD_UNLOCK="0"
  EFF_FEAT_BLUR="0"
  EFF_FEAT_ADV_TEXTURES="0"
  EFF_FEAT_ANIMATIONS="0"
  EFF_FEAT_XML_PATCHER="0"
  EFF_FEAT_RRO_OVERLAYS="0"
  EFF_FEAT_VIDEO_DEPTH="0"
  EFF_FEAT_MULTITASK="0"
  EFF_FEAT_DISPLAY_HZ="0"
  EFF_FEAT_COLOR_EXPERT="0"
  EFF_FEAT_FLAGSHIP_AUDIO="0"
  EFF_FEAT_FLAGSHIP_SUITE="0"

  export CS_EFF_TIER CS_EFF_TIER_LABEL \
    EFF_FEAT_AOD_UNLOCK \
    EFF_FEAT_BLUR EFF_FEAT_ADV_TEXTURES EFF_FEAT_ANIMATIONS EFF_FEAT_XML_PATCHER \
    EFF_FEAT_RRO_OVERLAYS EFF_FEAT_VIDEO_DEPTH EFF_FEAT_MULTITASK \
    EFF_FEAT_DISPLAY_HZ EFF_FEAT_COLOR_EXPERT \
    EFF_FEAT_FLAGSHIP_AUDIO EFF_FEAT_FLAGSHIP_SUITE

  # Native Flagship Passthrough (motion_only):
  # Factory ROM already has device_level >= 3 + blur -> skip redundant overrides cleanly!
  if [ "$CS_EFF_TIER" = "motion_only" ]; then
    # Only patch XML if stock flagship XML doesn't already expose Custom Color Expert
    if [ "$CFG_FEAT_COLOR_EXPERT" != "0" ] && [ "${CS_STOCK_HAS_EXPERT_COLOR:-0}" != "1" ]; then
      EFF_FEAT_XML_PATCHER="1"
      EFF_FEAT_COLOR_EXPERT="1"
    fi
    return 0
  fi

  # Standard Blur is ON in ALL non-passthrough tiers (including Lite!),
  # but Advanced Textures XML is NEVER enabled in Lite mode.
  case "$CFG_FEAT_BLUR" in
    1|auto)
      EFF_FEAT_BLUR="1"
      if [ "$CS_EFF_TIER" != "low" ]; then
        EFF_FEAT_ADV_TEXTURES="1"
      fi
      ;;
    0)
      EFF_FEAT_BLUR="0"
      EFF_FEAT_ADV_TEXTURES="0"
      ;;
  esac

  # Animations: ON across all tiers (scaled by CS_EFF_TIER, never downgrades stock level)
  case "$CFG_FEAT_ANIMATIONS" in
    1|auto) EFF_FEAT_ANIMATIONS="1" ;;
  esac

  # Dynamic XML Patcher: ON across all tiers
  case "$CFG_FEAT_XML_PATCHER" in
    1|auto) EFF_FEAT_XML_PATCHER="1" ;;
  esac

  # Custom Color Scheme Expert Mode: ALWAYS ON across ALL tiers (unless explicitly 0)
  case "$CFG_FEAT_COLOR_EXPERT" in
    1|auto)
      if [ "$EFF_FEAT_XML_PATCHER" = "1" ]; then
        EFF_FEAT_COLOR_EXPERT="1"
      fi
      ;;
  esac

  # Clean-Room RRO Overlays: ON across all tiers (Lite skips heavy MiWallpaper)
  case "$CFG_FEAT_RRO_OVERLAYS" in
    1|auto) EFF_FEAT_RRO_OVERLAYS="1" ;;
  esac

  # Lockscreen Video Depth: ON in Balanced Pro & Max Flagship on HyperOS (OFF in Lite)
  case "$CFG_FEAT_VIDEO_DEPTH" in
    1)
      if [ "$CS_ROM_FAMILY" = "hyperos" ]; then
        EFF_FEAT_VIDEO_DEPTH="1"
      fi
      ;;
    auto)
      if [ "$CS_ROM_FAMILY" = "hyperos" ] && [ "$CS_EFF_TIER" != "low" ]; then
        EFF_FEAT_VIDEO_DEPTH="1"
      fi
      ;;
  esac

  # Multitasking & High Refresh Rate: ON in Balanced Pro & Max Flagship (OFF in Lite)
  case "$CFG_FEAT_MULTITASK" in
    1) EFF_FEAT_MULTITASK="1" ;;
    auto)
      if [ "$CS_EFF_TIER" != "low" ]; then
        EFF_FEAT_MULTITASK="1"
      fi
      ;;
  esac

  case "$CFG_FEAT_DISPLAY_HZ" in
    1) EFF_FEAT_DISPLAY_HZ="1" ;;
    auto)
      if [ "$CS_EFF_TIER" != "low" ]; then
        EFF_FEAT_DISPLAY_HZ="1"
      fi
      ;;
  esac

  # Non-LTPO AOD Always-On Unlock (RRO + XML is_only_support_keycode_goto=false + MiuiAod hook)
  case "$CFG_FEAT_AOD_UNLOCK" in
    1|auto) EFF_FEAT_AOD_UNLOCK="1" ;;
  esac

  # Flagship Audio & Speaker Enhancement: ON across all non-passthrough tiers (0 GPU/RAM penalty)
  case "$CFG_FEAT_FLAGSHIP_AUDIO" in
    1|auto) EFF_FEAT_FLAGSHIP_AUDIO="1" ;;
  esac

  # Flagship Exclusive Porting Suite (AI Image Engine, Video Toolbox, Dynamic Font Anim, Wild Boost, Live Photo):
  # ON in Balanced Pro & Max Flagship (OFF in Lite unless explicitly enabled)
  case "$CFG_FEAT_FLAGSHIP_SUITE" in
    1) EFF_FEAT_FLAGSHIP_SUITE="1" ;;
    auto)
      if [ "$CS_EFF_TIER" != "low" ]; then
        EFF_FEAT_FLAGSHIP_SUITE="1"
      fi
      ;;
  esac
}
