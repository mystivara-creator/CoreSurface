#!/system/bin/sh
# CoreSurface - Layer 1 (ROM & SDK Gate) & Layer 2 (Dynamic Hardware Tiering)
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
# Sets: CFG_FEAT_BLUR, CFG_FEAT_ANIMATIONS, CFG_FEAT_XML_PATCHER,
#       CFG_FEAT_MULTITASK, CFG_FEAT_DISPLAY_HZ, CFG_FEAT_HYPERAI, CFG_FEAT_AOD_UNLOCK
cs_load_config() {
  _cs_cfg_file=$1

  CFG_FEAT_BLUR="auto"
  CFG_FEAT_ANIMATIONS="auto"
  CFG_FEAT_XML_PATCHER="auto"
  CFG_FEAT_MULTITASK="auto"
  CFG_FEAT_DISPLAY_HZ="auto"
  CFG_FEAT_HYPERAI="0"
  CFG_FEAT_AOD_UNLOCK="0"
  export CFG_FEAT_BLUR CFG_FEAT_ANIMATIONS CFG_FEAT_XML_PATCHER \
    CFG_FEAT_MULTITASK CFG_FEAT_DISPLAY_HZ CFG_FEAT_HYPERAI CFG_FEAT_AOD_UNLOCK

  [ -r "$_cs_cfg_file" ] || return 0

  while IFS='=' read -r _cs_k _cs_v || [ -n "$_cs_k" ]; do
    _cs_k=$(printf '%s' "$_cs_k" | tr -d '\r')
    _cs_v=$(printf '%s' "$_cs_v" | tr -d '\r')
    case "$_cs_k" in
      ''|'#'*) continue ;;
      FEAT_BLUR)
        case "$_cs_v" in auto|1|0) CFG_FEAT_BLUR="$_cs_v" ;; esac
        ;;
      FEAT_ANIMATIONS)
        case "$_cs_v" in auto|1|0) CFG_FEAT_ANIMATIONS="$_cs_v" ;; esac
        ;;
      FEAT_XML_PATCHER)
        case "$_cs_v" in auto|1|0) CFG_FEAT_XML_PATCHER="$_cs_v" ;; esac
        ;;
      FEAT_MULTITASK)
        case "$_cs_v" in auto|1|0) CFG_FEAT_MULTITASK="$_cs_v" ;; esac
        ;;
      FEAT_DISPLAY_HZ)
        case "$_cs_v" in auto|1|0) CFG_FEAT_DISPLAY_HZ="$_cs_v" ;; esac
        ;;
      FEAT_HYPERAI)
        case "$_cs_v" in 1|0) CFG_FEAT_HYPERAI="$_cs_v" ;; esac
        ;;
      FEAT_AOD_UNLOCK)
        case "$_cs_v" in 1|0) CFG_FEAT_AOD_UNLOCK="$_cs_v" ;; esac
        ;;
    esac
  done < "$_cs_cfg_file"
}

# Resolve effective per-feature enablement from config + dynamic hardware tiering.
# Sets: EFF_FEAT_BLUR, EFF_FEAT_ANIMATIONS, EFF_FEAT_XML_PATCHER,
#       EFF_FEAT_MULTITASK, EFF_FEAT_DISPLAY_HZ, EFF_FEAT_HYPERAI, EFF_FEAT_AOD_UNLOCK
cs_resolve_features() {
  EFF_FEAT_BLUR="0"
  EFF_FEAT_ANIMATIONS="0"
  EFF_FEAT_XML_PATCHER="0"
  EFF_FEAT_MULTITASK="0"
  EFF_FEAT_DISPLAY_HZ="0"
  EFF_FEAT_HYPERAI="0"
  EFF_FEAT_AOD_UNLOCK="0"
  export EFF_FEAT_BLUR EFF_FEAT_ANIMATIONS EFF_FEAT_XML_PATCHER \
    EFF_FEAT_MULTITASK EFF_FEAT_DISPLAY_HZ EFF_FEAT_HYPERAI EFF_FEAT_AOD_UNLOCK

  # FEAT_BLUR: High GPU/RAM load -> default ON only if RAM >= 6 GB (mid/high)
  case "$CFG_FEAT_BLUR" in
    1) EFF_FEAT_BLUR="1" ;;
    auto)
      if [ "$CS_RAM_TIER" != "low" ]; then
        EFF_FEAT_BLUR="1"
      fi
      ;;
    0) EFF_FEAT_BLUR="0" ;;
  esac

  # FEAT_ANIMATIONS: Default ON across all tiers (device_level scales with RAM tier)
  case "$CFG_FEAT_ANIMATIONS" in
    1|auto) EFF_FEAT_ANIMATIONS="1" ;;
    0) EFF_FEAT_ANIMATIONS="0" ;;
  esac

  # FEAT_XML_PATCHER: Default ON (fail-closed dynamic bind-mount)
  case "$CFG_FEAT_XML_PATCHER" in
    1|auto) EFF_FEAT_XML_PATCHER="1" ;;
    0) EFF_FEAT_XML_PATCHER="0" ;;
  esac

  # FEAT_MULTITASK: Default ON only when RAM >= 8 GB (high)
  case "$CFG_FEAT_MULTITASK" in
    1) EFF_FEAT_MULTITASK="1" ;;
    auto)
      if [ "$CS_RAM_TIER" = "high" ]; then
        EFF_FEAT_MULTITASK="1"
      fi
      ;;
    0) EFF_FEAT_MULTITASK="0" ;;
  esac

  # FEAT_DISPLAY_HZ: Default ON only when RAM >= 8 GB (high)
  case "$CFG_FEAT_DISPLAY_HZ" in
    1) EFF_FEAT_DISPLAY_HZ="1" ;;
    auto)
      if [ "$CS_RAM_TIER" = "high" ]; then
        EFF_FEAT_DISPLAY_HZ="1"
      fi
      ;;
    0) EFF_FEAT_DISPLAY_HZ="0" ;;
  esac

  # FEAT_HYPERAI: Opt-in only; version-gated on HyperOS + Android SDK >= 34
  if [ "$CFG_FEAT_HYPERAI" = "1" ] && [ "$CS_ROM_FAMILY" = "hyperos" ] && [ "$CS_ANDROID_SDK" -ge 34 ]; then
    EFF_FEAT_HYPERAI="1"
  fi

  # FEAT_AOD_UNLOCK: Opt-in only
  if [ "$CFG_FEAT_AOD_UNLOCK" = "1" ]; then
    EFF_FEAT_AOD_UNLOCK="1"
  fi
}
