#!/system/bin/sh
# CoreSurface - Layer 1 (ROM & SDK Gate) & Layer 2 (Dynamic Hardware Tiering)
# Pure POSIX sh. No hardcoded device codenames.

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
    # Extract leading digits after optional prefix (e.g. OS1.0 -> 1, OS2.0 -> 2, OS3.1 -> 3)
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

# Read MemTotal from /proc/meminfo (or CORESURFACE_MEMINFO override) in MB.
# Sets: CS_RAM_MB, CS_RAM_TIER (low | mid | high), CS_RAM_TIER_LABEL
cs_detect_ram_tier() {
  _cs_meminfo=${CORESURFACE_MEMINFO:-/proc/meminfo}
  CS_RAM_MB="0"
  CS_RAM_TIER="low"
  CS_RAM_TIER_LABEL="< 6 GB"
  export CS_RAM_MB CS_RAM_TIER CS_RAM_TIER_LABEL

  if [ -r "$_cs_meminfo" ]; then
    _cs_kb=$(awk '/^MemTotal:/ { print $2; exit }' "$_cs_meminfo" 2>/dev/null || true)
    if cs_is_uint "$_cs_kb"; then
      CS_RAM_MB=$((_cs_kb / 1024))
    fi
  fi

  # Physical 6 GB devices typically expose ~5632-6000 MB to Linux;
  # Physical 8 GB devices typically expose ~7168-8000 MB to Linux.
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
}

# Load user config safely without executing arbitrary shell code.
# Sets: CFG_TIER1_VISUAL, CFG_TIER2_MULTITASK, CFG_TIER3_EXPERIMENTAL,
#       CFG_TIER3_HYPERAI, CFG_TIER3_AOD_UNLOCK
cs_load_config() {
  _cs_cfg_file=$1

  CFG_TIER1_VISUAL="auto"
  CFG_TIER2_MULTITASK="auto"
  CFG_TIER3_EXPERIMENTAL="0"
  CFG_TIER3_HYPERAI="0"
  CFG_TIER3_AOD_UNLOCK="0"
  export CFG_TIER1_VISUAL CFG_TIER2_MULTITASK CFG_TIER3_EXPERIMENTAL CFG_TIER3_HYPERAI CFG_TIER3_AOD_UNLOCK

  [ -r "$_cs_cfg_file" ] || return 0

  while IFS='=' read -r _cs_k _cs_v || [ -n "$_cs_k" ]; do
    # Strip CR if present
    _cs_k=$(printf '%s' "$_cs_k" | tr -d '\r')
    _cs_v=$(printf '%s' "$_cs_v" | tr -d '\r')
    case "$_cs_k" in
      ''|'#'*) continue ;;
      TIER1_VISUAL)
        case "$_cs_v" in auto|1|0) CFG_TIER1_VISUAL="$_cs_v" ;; esac
        ;;
      TIER2_MULTITASK)
        case "$_cs_v" in auto|1|0) CFG_TIER2_MULTITASK="$_cs_v" ;; esac
        ;;
      TIER3_EXPERIMENTAL)
        case "$_cs_v" in 1|0) CFG_TIER3_EXPERIMENTAL="$_cs_v" ;; esac
        ;;
      TIER3_HYPERAI)
        case "$_cs_v" in 1|0) CFG_TIER3_HYPERAI="$_cs_v" ;; esac
        ;;
      TIER3_AOD_UNLOCK)
        case "$_cs_v" in 1|0) CFG_TIER3_AOD_UNLOCK="$_cs_v" ;; esac
        ;;
    esac
  done < "$_cs_cfg_file"
}

# Resolve effective tier enablement from config + dynamic hardware tiering.
# Sets: EFF_TIER1, EFF_TIER1_HEAVY_BLUR, EFF_TIER2, EFF_TIER3,
#       EFF_TIER3_HYPERAI, EFF_TIER3_AOD_UNLOCK
cs_resolve_tiers() {
  EFF_TIER1="0"
  EFF_TIER1_HEAVY_BLUR="0"
  EFF_TIER2="0"
  EFF_TIER3="0"
  EFF_TIER3_HYPERAI="0"
  EFF_TIER3_AOD_UNLOCK="0"
  export EFF_TIER1 EFF_TIER1_HEAVY_BLUR EFF_TIER2 EFF_TIER3 EFF_TIER3_HYPERAI EFF_TIER3_AOD_UNLOCK

  # Tier 1: Default ON; heavy blur gated on RAM >= 6 GB (mid/high)
  case "$CFG_TIER1_VISUAL" in
    1)
      EFF_TIER1="1"
      if [ "$CS_RAM_TIER" != "low" ]; then
        EFF_TIER1_HEAVY_BLUR="1"
      fi
      ;;
    auto)
      EFF_TIER1="1"
      if [ "$CS_RAM_TIER" != "low" ]; then
        EFF_TIER1_HEAVY_BLUR="1"
      fi
      ;;
    0)
      EFF_TIER1="0"
      EFF_TIER1_HEAVY_BLUR="0"
      ;;
  esac

  # Tier 2: Default ON only when RAM >= 8 GB (high)
  case "$CFG_TIER2_MULTITASK" in
    1)
      EFF_TIER2="1"
      ;;
    auto)
      if [ "$CS_RAM_TIER" = "high" ]; then
        EFF_TIER2="1"
      else
        EFF_TIER2="0"
      fi
      ;;
    0)
      EFF_TIER2="0"
      ;;
  esac

  # Tier 3: Default OFF, opt-in only; HyperAI gated on HyperOS + SDK >= 34
  if [ "$CFG_TIER3_EXPERIMENTAL" = "1" ]; then
    EFF_TIER3="1"
    if [ "$CFG_TIER3_HYPERAI" = "1" ] && [ "$CS_ROM_FAMILY" = "hyperos" ] && [ "$CS_ANDROID_SDK" -ge 34 ]; then
      EFF_TIER3_HYPERAI="1"
    fi
    if [ "$CFG_TIER3_AOD_UNLOCK" = "1" ]; then
      EFF_TIER3_AOD_UNLOCK="1"
    fi
  fi
}
