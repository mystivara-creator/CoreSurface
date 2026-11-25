#!/system/bin/sh
# CoreSurface - Layer 1 (ROM & SDK Gate) & Layer 2 (Dynamic Hardware & 4-Tier Classification)
# Pure POSIX sh. Zero hardcoded device codenames.

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

# Read MemTotal from /proc/meminfo (or CORESURFACE_MEMINFO override) in MB
# and classify hardware class dynamically (distinguishing Entry/Mid Non-Pro,
# Mid-Range Pro/Pro+, and Flagship without hardcoding any device codenames).
# Sets: CS_RAM_MB, CS_RAM_TIER (low | mid | high), CS_RAM_TIER_LABEL,
#       CS_DETECTED_TIER (low | balanced_pro | flagship), CS_DETECTED_TIER_LABEL
cs_detect_ram_tier() {
  _cs_meminfo=${CORESURFACE_MEMINFO:-/proc/meminfo}
  CS_RAM_MB="0"
  CS_RAM_TIER="low"
  CS_RAM_TIER_LABEL="< 6 GB"
  CS_DETECTED_TIER="low"
  CS_DETECTED_TIER_LABEL="Low (Entry / Mid Non-Pro)"
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

  _cs_mkt=$(cs_getprop "ro.product.marketname")
  if [ -z "$_cs_mkt" ]; then
    _cs_mkt=$(cs_getprop "ro.product.model")
  fi
  _cs_mkt_lc=$(printf '%s' "$_cs_mkt" | tr '[:upper:]' '[:lower:]')
  _cs_stock_lvl=$(cs_getprop "ro.miui.device_level")

  # Dynamic hardware class classification (zero hardcoded codenames):
  # - Flagship: >= 12 GB RAM, stock device_level >= 3, or Ultra/Fold/Flip/Mix tier
  # - Balance Pro/Pro+: >= 6 GB RAM + Pro/Pro+/Turbo/GT tier (e.g., Redmi Note Pro/Pro+, POCO X Pro)
  # - Low (Entry / Mid Non-Pro): < 6 GB RAM OR non-Pro mid-range (e.g., Redmi Note 15 5G)
  if [ "$CS_RAM_MB" -ge 10240 ]; then
    CS_DETECTED_TIER="flagship"
    CS_DETECTED_TIER_LABEL="Flagship Tier"
  elif cs_is_uint "$_cs_stock_lvl" && [ "$_cs_stock_lvl" -ge 3 ]; then
    CS_DETECTED_TIER="flagship"
    CS_DETECTED_TIER_LABEL="Flagship Tier"
  else
    case "$_cs_mkt_lc" in
      *ultra*|*fold*|*flip*|*mix*)
        if [ "$CS_RAM_MB" -ge 7168 ]; then
          CS_DETECTED_TIER="flagship"
          CS_DETECTED_TIER_LABEL="Flagship Tier"
        else
          CS_DETECTED_TIER="balanced_pro"
          CS_DETECTED_TIER_LABEL="Balance Pro / Pro+"
        fi
        ;;
      *pro*|*turbo*|*gt*)
        if [ "$CS_RAM_MB" -ge 5632 ]; then
          CS_DETECTED_TIER="balanced_pro"
          CS_DETECTED_TIER_LABEL="Balance Pro / Pro+"
        else
          CS_DETECTED_TIER="low"
          CS_DETECTED_TIER_LABEL="Low (Entry / Mid Non-Pro)"
        fi
        ;;
      '')
        # Fallback when marketname/model is not exposed: use RAM tier
        if [ "$CS_RAM_MB" -ge 7168 ]; then
          CS_DETECTED_TIER="balanced_pro"
          CS_DETECTED_TIER_LABEL="Balance Pro / Pro+"
        else
          CS_DETECTED_TIER="low"
          CS_DETECTED_TIER_LABEL="Low (Entry / Mid Non-Pro)"
        fi
        ;;
      *)
        # Named non-Pro mid-range / entry device (e.g., Redmi Note 15 5G) -> Low (Blur ON, no Advanced Textures)
        CS_DETECTED_TIER="low"
        CS_DETECTED_TIER_LABEL="Low (Entry / Mid Non-Pro)"
        ;;
    esac
  fi
}

# Load user config safely without executing arbitrary shell code.
cs_load_config() {
  _cs_cfg_file=$1

  CFG_TIER_MODE="auto"
  CFG_FEAT_MOTION_PROFILE="hyperos4"
  CFG_FEAT_NATIVE_TIER="auto"
  CFG_FEAT_SURGICAL_GUARD="1"
  CFG_FEAT_THERMAL_LOD="auto"
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

  export CFG_TIER_MODE CFG_FEAT_MOTION_PROFILE CFG_FEAT_NATIVE_TIER \
    CFG_FEAT_SURGICAL_GUARD CFG_FEAT_THERMAL_LOD CFG_FEAT_AOD_UNLOCK \
    CFG_FEAT_BLUR CFG_FEAT_ANIMATIONS CFG_FEAT_XML_PATCHER CFG_FEAT_RRO_OVERLAYS \
    CFG_FEAT_VIDEO_DEPTH CFG_FEAT_MULTITASK CFG_FEAT_DISPLAY_HZ CFG_FEAT_COLOR_EXPERT

  [ -r "$_cs_cfg_file" ] || return 0

  _cs_seen_native_tier="0"
  while IFS='=' read -r _cs_k _cs_v || [ -n "$_cs_k" ]; do
    _cs_k=$(printf '%s' "$_cs_k" | tr -d '\r')
    _cs_v=$(printf '%s' "$_cs_v" | tr -d '\r')
    case "$_cs_k" in
      ''|'#'*) continue ;;
      CS_TIER_MODE)
        case "$_cs_v" in
          auto|low|balanced_pro|flagship) CFG_TIER_MODE="$_cs_v" ;;
        esac
        ;;
      FEAT_MOTION_PROFILE)
        case "$_cs_v" in
          hyperos4|silk|0) CFG_FEAT_MOTION_PROFILE="$_cs_v" ;;
          off) CFG_FEAT_MOTION_PROFILE="0" ;;
        esac
        ;;
      FEAT_NATIVE_TIER)
        case "$_cs_v" in
          auto|1|0)
            CFG_FEAT_NATIVE_TIER="$_cs_v"
            _cs_seen_native_tier="1"
            ;;
        esac
        ;;
      FEAT_LIVING_FLOW)
        if [ "$_cs_seen_native_tier" = "0" ]; then
          case "$_cs_v" in auto|1|0) CFG_FEAT_NATIVE_TIER="$_cs_v" ;; esac
        fi
        ;;
      FEAT_SURGICAL_GUARD)
        case "$_cs_v" in auto|1|0) CFG_FEAT_SURGICAL_GUARD="$_cs_v" ;; esac
        ;;
      FEAT_THERMAL_LOD)
        case "$_cs_v" in auto|1|0) CFG_FEAT_THERMAL_LOD="$_cs_v" ;; esac
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
    esac
  done < "$_cs_cfg_file"
}

# Resolve effective tier (low | balanced_pro | flagship) and per-feature flags.
cs_resolve_features() {
  case "$CFG_TIER_MODE" in
    low)          CS_EFF_TIER="low" ;;
    balanced_pro) CS_EFF_TIER="balanced_pro" ;;
    flagship)     CS_EFF_TIER="flagship" ;;
    *)            CS_EFF_TIER="${CS_DETECTED_TIER:-low}" ;;
  esac

  case "$CS_EFF_TIER" in
    flagship)     CS_EFF_TIER_LABEL="Flagship Tier" ;;
    balanced_pro) CS_EFF_TIER_LABEL="Balance Pro / Pro+" ;;
    *)            CS_EFF_TIER_LABEL="Low (Blur Standar, Tanpa Advanced Textures)" ;;
  esac

  EFF_FEAT_MOTION_PROFILE="off"
  EFF_FEAT_NATIVE_TIER="0"
  EFF_FEAT_SURGICAL_GUARD="0"
  EFF_FEAT_THERMAL_LOD="0"
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

  export CS_EFF_TIER CS_EFF_TIER_LABEL \
    EFF_FEAT_MOTION_PROFILE EFF_FEAT_NATIVE_TIER \
    EFF_FEAT_SURGICAL_GUARD EFF_FEAT_THERMAL_LOD EFF_FEAT_AOD_UNLOCK \
    EFF_FEAT_BLUR EFF_FEAT_ADV_TEXTURES EFF_FEAT_ANIMATIONS EFF_FEAT_XML_PATCHER \
    EFF_FEAT_RRO_OVERLAYS EFF_FEAT_VIDEO_DEPTH EFF_FEAT_MULTITASK \
    EFF_FEAT_DISPLAY_HZ EFF_FEAT_COLOR_EXPERT

  # Live Motion Profile
  case "$CFG_FEAT_MOTION_PROFILE" in
    hyperos4) EFF_FEAT_MOTION_PROFILE="hyperos4" ;;
    silk)     EFF_FEAT_MOTION_PROFILE="silk" ;;
    *)        EFF_FEAT_MOTION_PROFILE="off" ;;
  esac

  # Native Flagship Tier Unlock, Surgical Guard & Thermal-Adaptive Motion
  case "$CFG_FEAT_NATIVE_TIER" in
    1|auto) EFF_FEAT_NATIVE_TIER="1" ;;
  esac
  case "$CFG_FEAT_SURGICAL_GUARD" in
    1|auto) EFF_FEAT_SURGICAL_GUARD="1" ;;
  esac
  case "$CFG_FEAT_THERMAL_LOD" in
    1|auto) EFF_FEAT_THERMAL_LOD="1" ;;
  esac

  # Standard Blur is ON in ALL tiers (including Low!), but Advanced Textures XML
  # is NEVER enabled in Low mode.
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

  # Animations: ON across all tiers (scaled by CS_EFF_TIER: low=Lvl2, balanced_pro=Lvl2+, flagship=Lvl3)
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

  # Clean-Room RRO Overlays: ON across all tiers (Low skips heavy MiWallpaper)
  case "$CFG_FEAT_RRO_OVERLAYS" in
    1|auto) EFF_FEAT_RRO_OVERLAYS="1" ;;
  esac

  # Lockscreen Video Depth: ON in Balance Pro/Pro+ & Flagship on HyperOS (OFF in Low)
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

  # Multitasking & High Refresh Rate: ON in Balance Pro/Pro+ & Flagship (OFF in Low for lightness)
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

  # Non-LTPO AOD Always-On Unlock (RRO + XML + MiuiAod hook)
  case "$CFG_FEAT_AOD_UNLOCK" in
    1|auto) EFF_FEAT_AOD_UNLOCK="1" ;;
  esac
}
