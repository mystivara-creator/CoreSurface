#!/system/bin/sh
# CoreSurface - Hardware-Verified Camera2 Prober, Dual-Support Leica Bridge &
# On-Boot/On-Demand Camera Crash Inspector (0 KB Background Daemon)
# Pure POSIX sh + awk. Zero hardcoded device codenames. Zero /vendor/etc/camera writes.

CS_CAM_CAPS_FILE="$CS_STATE_DIR/camera_caps.prop"
CS_CAM_WATCHDOG_FILE="$CS_STATE_DIR/camera_watchdog.state"

# Safe timeout wrapper (supports Toybox/GNU `timeout <sec>` and legacy BusyBox `timeout -t <sec>`)
_cs_cam_timeout_run() {
  _cs_ctr_sec=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    if timeout 1 true >/dev/null 2>&1; then
      timeout "$_cs_ctr_sec" "$@"
    else
      timeout -t "$_cs_ctr_sec" "$@"
    fi
  else
    "$@"
  fi
}

# Stream dumpsys safely with variadic arguments (e.g., `_cs_cam_dumpsys package com.android.camera`)
# Supports UID 2000 fallback for Android 15/16 KernelSU root Binder restrictions.
_cs_cam_dumpsys() {
  [ "$#" -ge 1 ] || return 1
  command -v dumpsys >/dev/null 2>&1 || return 1

  _cs_cd_tmp="${CS_STATE_DIR:-/tmp}/.cam_ds.$$"
  rm -f "$_cs_cd_tmp" 2>/dev/null || true

  _cs_cam_timeout_run 6 dumpsys "$@" > "$_cs_cd_tmp" 2>/dev/null || true
  if [ ! -s "$_cs_cd_tmp" ] && command -v su >/dev/null 2>&1; then
    _cs_cam_timeout_run 6 su 2000 -c "dumpsys $*" > "$_cs_cd_tmp" 2>/dev/null || true
  fi
  if [ ! -s "$_cs_cd_tmp" ]; then
    for _cs_cbb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
      if [ -x "$_cs_cbb" ]; then
        _cs_cam_timeout_run 6 "$_cs_cbb" setuidgid 2000 dumpsys "$@" > "$_cs_cd_tmp" 2>/dev/null || true
        break
      fi
    done
  fi

  if [ -s "$_cs_cd_tmp" ]; then
    cat "$_cs_cd_tmp"
    rm -f "$_cs_cd_tmp" 2>/dev/null || true
    return 0
  fi
  rm -f "$_cs_cd_tmp" 2>/dev/null || true
  return 1
}

# Detect SoC ISP family from ro.board.platform / ro.hardware (read-only)
cs_camera_detect_isp() {
  _cs_plat=$(cs_getprop "ro.board.platform" | tr '[:upper:]' '[:lower:]')
  _cs_hw=$(cs_getprop "ro.hardware" | tr '[:upper:]' '[:lower:]')
  _cs_comb="${_cs_plat}|${_cs_hw}"

  case "$_cs_comb" in
    *qcom*|*msm*|*sdm*|*sm[0-9]*|*kalama*|*pineapple*|*sun*|*crow*|*garnet*|*taro*|*lahaina*|*kona*|*bengal*|*holi*|*parrots*|*volcano*|*cliffs*|*kera*|*canoe*)
      printf 'snapdragon\n'
      ;;
    *mt[0-9]*|*mediatek*|*dimensity*|*helio*)
      printf 'mediatek\n'
      ;;
    *xring*|*xr[0-9]*)
      printf 'xring\n'
      ;;
    *)
      printf 'generic\n'
      ;;
  esac
}

# Detect active external/Mystivara Leica Camera Companion module in /data/adb/modules
# Strict anti-false-positive rule: requires an actual MiuiCamera/Camera APK overlay directory
# OR an explicit Leica/CoreCam match on `id=` / `name=` lines (NEVER arbitrary description= text).
# Sets: CS_CAM_COMPANION_ID, CS_CAM_COMPANION_NAME
cs_camera_detect_companion() {
  CS_CAM_COMPANION_ID=""
  CS_CAM_COMPANION_NAME=""
  _cs_mods_dir=${CORESURFACE_MODULES_DIR:-/data/adb/modules}
  [ -d "$_cs_mods_dir" ] || return 0

  for _cs_mdir in "$_cs_mods_dir"/*; do
    [ -d "$_cs_mdir" ] || continue
    _cs_mid=$(basename -- "$_cs_mdir")
    [ "$_cs_mid" = "coresurface" ] && continue
    [ -f "$_cs_mdir/disable" ] && continue
    [ -f "$_cs_mdir/remove" ] && continue

    _cs_mprop="$_cs_mdir/module.prop"
    _cs_is_leica=0
    _cs_mname=""
    _cs_mid_prop=""
    if [ -r "$_cs_mprop" ]; then
      _cs_mname=$(awk -F '=' '$1 == "name" { sub(/^[^=]*=/, ""); print; exit }' "$_cs_mprop" 2>/dev/null | tr -d '\r')
      _cs_mid_prop=$(awk -F '=' '$1 == "id" { sub(/^[^=]*=/, ""); print; exit }' "$_cs_mprop" 2>/dev/null | tr -d '\r')
    fi

    if [ -d "$_cs_mdir/system/priv-app/MiuiCamera" ] || \
       [ -d "$_cs_mdir/system/product/priv-app/MiuiCamera" ] || \
       [ -d "$_cs_mdir/system/system_ext/priv-app/MiuiCamera" ] || \
       [ -d "$_cs_mdir/system/priv-app/Camera" ] || \
       [ -d "$_cs_mdir/system/product/priv-app/Camera" ]; then
      _cs_is_leica=1
    elif printf '%s|%s\n' "$_cs_mid_prop" "$_cs_mname" | grep -i -E '(leica|corecam|miuicamera|sevtinge|holybear)' >/dev/null 2>&1; then
      _cs_is_leica=1
    fi

    if [ "$_cs_is_leica" = "1" ]; then
      CS_CAM_COMPANION_ID="$_cs_mid"
      CS_CAM_COMPANION_NAME="${_cs_mname:-$_cs_mid}"
      return 0
    fi
  done
  return 0
}

# Check unmodified stock device_features XML & read-only factory props for Native Leica
cs_camera_probe_stock_leica() {
  _cs_sl_prop=$(cs_getprop "ro.miui.camera.leica")
  if [ "$_cs_sl_prop" = "1" ] || [ "$_cs_sl_prop" = "true" ]; then
    printf '1\n'
    return 0
  fi

  _cs_sl_dirs=${CORESURFACE_XML_SEARCH_DIRS:-/mi_ext/product/etc/device_features:/product/etc/device_features:/system/etc/device_features:/vendor/etc/device_features}
  _cs_sl_dev=$(cs_getprop "ro.product.device")
  _cs_sl_xml=""

  if [ -n "$_cs_sl_dev" ]; then
    _cs_old_ifs=$IFS
    IFS=':'
    for _cs_d in $_cs_sl_dirs; do
      IFS=$_cs_old_ifs
      if [ -r "${_cs_d}/${_cs_sl_dev}.xml" ]; then
        _cs_sl_xml="${_cs_d}/${_cs_sl_dev}.xml"
        break
      fi
    done
    IFS=$_cs_old_ifs
  fi

  if [ -n "$_cs_sl_xml" ] && [ -r "$_cs_sl_xml" ]; then
    if grep -E '<bool name="(is_support_leica|support_leica_watermark|support_cv_type|support_leica_lens)">true</bool>' "$_cs_sl_xml" >/dev/null 2>&1; then
      printf '1\n'
      return 0
    fi
  fi

  printf '0\n'
  return 0
}

# Initialize default camera capability globals
cs_camera_reset_globals() {
  CS_CAM_PROBED="0"
  CS_CAM_NEWLY_PROBED="0"
  CS_CAM_ISP="generic"
  CS_CAM_HAL_LEVEL="UNKNOWN"
  CS_CAM_HAS_RAW="0"
  CS_CAM_HAS_MANUAL="0"
  CS_CAM_HAS_10BIT="0"
  CS_CAM_HAS_4K60="0"
  CS_CAM_HAS_LOGICAL_MULTI="0"
  CS_CAM_LENS_COUNT="0"
  CS_CAM_APK_VERSION="unknown"
  CS_CAM_STOCK_HAS_LEICA="0"
  CS_CAM_LEICA_SOURCE="none"
  CS_CAM_COMPANION_ID=""
  CS_CAM_COMPANION_NAME=""
  CS_CAM_CRASH_COUNT="0"
  CS_CAM_WATCHDOG_STATUS="healthy"
  CS_CAM_WATCHDOG_REASON="none"
  CS_CAM_SERVICE_HEALTH="unknown"
  export CS_CAM_PROBED CS_CAM_NEWLY_PROBED CS_CAM_ISP CS_CAM_HAL_LEVEL CS_CAM_HAS_RAW CS_CAM_HAS_MANUAL \
    CS_CAM_HAS_10BIT CS_CAM_HAS_4K60 CS_CAM_HAS_LOGICAL_MULTI CS_CAM_LENS_COUNT \
    CS_CAM_APK_VERSION CS_CAM_STOCK_HAS_LEICA CS_CAM_LEICA_SOURCE \
    CS_CAM_COMPANION_ID CS_CAM_COMPANION_NAME \
    CS_CAM_CRASH_COUNT CS_CAM_WATCHDOG_STATUS CS_CAM_WATCHDOG_REASON CS_CAM_SERVICE_HEALTH
}

# Fast single-pass POSIX reader of cached camera_caps.prop and camera_watchdog.state
cs_camera_load_caps() {
  cs_camera_reset_globals
  _cs_cdir=${CS_STATE_DIR:-${CORESURFACE_STATE_DIR:-/data/adb/coresurface}}
  _cs_cfile="${_cs_cdir}/camera_caps.prop"
  _cs_wfile="${_cs_cdir}/camera_watchdog.state"

  if [ -r "$_cs_cfile" ]; then
    while IFS='=' read -r _ck _cv || [ -n "$_ck" ]; do
      _ck=$(printf '%s' "$_ck" | tr -d '\r')
      _cv=$(printf '%s' "$_cv" | tr -d '\r')
      case "$_ck" in
        CAM_PROBED)            CS_CAM_PROBED="$_cv" ;;
        CAM_ISP)               CS_CAM_ISP="$_cv" ;;
        CAM_HAL_LEVEL)         CS_CAM_HAL_LEVEL="$_cv" ;;
        CAM_HAS_RAW)           CS_CAM_HAS_RAW="$_cv" ;;
        CAM_HAS_MANUAL)        CS_CAM_HAS_MANUAL="$_cv" ;;
        CAM_HAS_10BIT)         CS_CAM_HAS_10BIT="$_cv" ;;
        CAM_HAS_4K60)          CS_CAM_HAS_4K60="$_cv" ;;
        CAM_HAS_LOGICAL_MULTI) CS_CAM_HAS_LOGICAL_MULTI="$_cv" ;;
        CAM_LENS_COUNT)        CS_CAM_LENS_COUNT="$_cv" ;;
        CAM_APK_VERSION)       CS_CAM_APK_VERSION="$_cv" ;;
        CAM_STOCK_HAS_LEICA)   CS_CAM_STOCK_HAS_LEICA="$_cv" ;;
        CAM_LEICA_SOURCE)      CS_CAM_LEICA_SOURCE="$_cv" ;;
        CAM_COMPANION_ID)      CS_CAM_COMPANION_ID="$_cv" ;;
        CAM_COMPANION_NAME)    CS_CAM_COMPANION_NAME="$_cv" ;;
      esac
    done < "$_cs_cfile"
  fi

  if [ -r "$_cs_wfile" ]; then
    while IFS='=' read -r _wk _wv || [ -n "$_wk" ]; do
      _wk=$(printf '%s' "$_wk" | tr -d '\r')
      _wv=$(printf '%s' "$_wv" | tr -d '\r')
      case "$_wk" in
        CAM_CRASH_COUNT)     CS_CAM_CRASH_COUNT="$_wv" ;;
        CAM_WATCHDOG_STATUS) CS_CAM_WATCHDOG_STATUS="$_wv" ;;
        CAM_WATCHDOG_REASON) CS_CAM_WATCHDOG_REASON="$_wv" ;;
        CAM_SERVICE_HEALTH)  CS_CAM_SERVICE_HEALTH="$_wv" ;;
      esac
    done < "$_cs_wfile"
  fi
}

# Streaming AWK parser for dumpsys media.camera (0 shell-variable megabyte buffering)
# Handles both symbolic ([FULL], [LEVEL_3]) and Android 14-16 numeric byte ([0]=LIMITED,
# [1]=FULL, [2]=LEGACY, [3]=LEVEL_3) dumpsys formats, and deduplicates camera IDs.
_cs_cam_parse_media_stream() {
  awk '
    function rank(lvl) {
      if (lvl == "LEVEL_3") return 4
      if (lvl == "FULL") return 3
      if (lvl == "LIMITED") return 2
      if (lvl == "LEGACY") return 1
      return 0
    }
    function apply_lvl(lvl) {
      if (rank(lvl) > best_rank) {
        best_lvl = lvl
        best_rank = rank(lvl)
      }
    }
    function parse_lvl_line(s) {
      if (index(s, "LEVEL_3") > 0) { apply_lvl("LEVEL_3"); return 1 }
      if (index(s, "FULL") > 0)    { apply_lvl("FULL"); return 1 }
      if (index(s, "LIMITED") > 0) { apply_lvl("LIMITED"); return 1 }
      if (index(s, "LEGACY") > 0)  { apply_lvl("LEGACY"); return 1 }
      # Android Camera2 metadata enum on value line (anchored so "byte[1]" header is never matched):
      # 0=LIMITED, 1=FULL, 2=LEGACY, 3=LEVEL_3
      if (s ~ /^[[:space:]]*\[[[:space:]]*3[[:space:]]*\]/) { apply_lvl("LEVEL_3"); return 1 }
      if (s ~ /^[[:space:]]*\[[[:space:]]*1[[:space:]]*\]/) { apply_lvl("FULL"); return 1 }
      if (s ~ /^[[:space:]]*\[[[:space:]]*0[[:space:]]*\]/) { apply_lvl("LIMITED"); return 1 }
      if (s ~ /^[[:space:]]*\[[[:space:]]*2[[:space:]]*\]/) { apply_lvl("LEGACY"); return 1 }
      return 0
    }
    BEGIN {
      best_lvl = "UNKNOWN"
      best_rank = 0
      raw = 0
      manual = 0
      tenbit = 0
      has4k60 = 0
      multi = 0
      in_caps = 0
      next_lvl = 0
      lines = 0
    }
    { lines++ }
    /^== Camera device [0-9]+/ || /^[[:space:]]*Device [0-9]+ is / {
      s = $0
      if (match(s, /[0-9]+/)) {
        cid = substr(s, RSTART, RLENGTH)
        seen_cam[cid] = 1
      }
    }
    /android\.info\.supportedHardwareLevel/ || /INFO_SUPPORTED_HARDWARE_LEVEL/ {
      if (parse_lvl_line($0)) {
        next_lvl = 0
      } else {
        next_lvl = 2
      }
      next
    }
    next_lvl > 0 {
      if (parse_lvl_line($0)) {
        next_lvl = 0
      } else {
        next_lvl--
      }
    }
    /android\.request\.availableCapabilities/ || /REQUEST_AVAILABLE_CAPABILITIES/ {
      in_caps = 1
    }
    in_caps == 1 {
      if ($0 ~ /REQUEST_AVAILABLE_CAPABILITIES_RAW/ || $0 ~ /(^|[^A-Z0-9_])RAW([^A-Z0-9_]|$)/) raw = 1
      if ($0 ~ /MANUAL_SENSOR/) manual = 1
      if ($0 ~ /DYNAMIC_RANGE_TEN_BIT/) tenbit = 1
      if ($0 ~ /LOGICAL_MULTI_CAMERA/) multi = 1
      if ($0 ~ /^[[:space:]]*android\./ && $0 !~ /availableCapabilities/) in_caps = 0
    }
    /DYNAMIC_RANGE_TEN_BIT/ || /HLG10/ { tenbit = 1 }
    /MANUAL_SENSOR/ { manual = 1 }
    /LOGICAL_MULTI_CAMERA/ { multi = 1 }
    /3840x2160/ {
      if ($0 ~ /60(\.0+)?([[:space:]]*fps|Hz|,|\])?/ || $0 ~ /minDuration[=: ]*16[0-9]{6}/) {
        has4k60 = 1
      }
    }
    /4K_60FPS|3840x2160@60/ { has4k60 = 1 }
    END {
      if (lines > 0) {
        # Android Camera2 CDD: RAW + MANUAL_SENSOR requires at least FULL hardware level
        if (best_lvl == "UNKNOWN" && raw == 1 && manual == 1) {
          best_lvl = "FULL"
        }
        lenses = 0
        for (k in seen_cam) lenses++
        printf "%s|%d|%d|%d|%d|%d|%d\n", best_lvl, raw, manual, tenbit, has4k60, multi, lenses
      }
    }
  ' 2>/dev/null || true
}

# Hardware-Verified Camera2 Prober (called during customize.sh, service.sh, or on-demand)
# Arg1: force=1 to bypass fingerprint cache
cs_camera_probe_hardware() {
  _cs_cp_force=${1:-0}
  cs_watchdog_init_dir || return 0
  cs_camera_load_caps
  _cs_was_probed="$CS_CAM_PROBED"

  _cs_cp_fp=$(cs_getprop "ro.build.fingerprint")
  _cs_cp_dev=$(cs_getprop "ro.product.device")
  _cs_cp_id="${_cs_cp_fp}|${_cs_cp_dev}|${CS_ROM_VERSION:-}"

  # Always refresh live companion detection (cheap filesystem check, 0 forks)
  cs_camera_detect_companion
  _cs_cp_comp_id="$CS_CAM_COMPANION_ID"
  _cs_cp_comp_name="$CS_CAM_COMPANION_NAME"

  if [ "$_cs_cp_force" != "1" ] && [ -r "$CS_CAM_CAPS_FILE" ]; then
    _cs_saved_cp_id=$(awk -F '=' '$1 == "CAM_SNAP_ID" { sub(/^[^=]*=/, ""); print; exit }' "$CS_CAM_CAPS_FILE" 2>/dev/null | tr -d '\r')
    _cs_saved_comp=$(awk -F '=' '$1 == "CAM_COMPANION_ID" { sub(/^[^=]*=/, ""); print; exit }' "$CS_CAM_CAPS_FILE" 2>/dev/null | tr -d '\r')
    if [ "$_cs_saved_cp_id" = "$_cs_cp_id" ] && [ "$_cs_saved_comp" = "$_cs_cp_comp_id" ] && [ "$CS_CAM_PROBED" = "1" ] && [ "$CS_CAM_HAL_LEVEL" != "UNKNOWN" ]; then
      return 0
    fi
  fi

  CS_CAM_ISP=$(cs_camera_detect_isp)
  CS_CAM_STOCK_HAS_LEICA=$(cs_camera_probe_stock_leica)
  CS_CAM_COMPANION_ID="$_cs_cp_comp_id"
  CS_CAM_COMPANION_NAME="$_cs_cp_comp_name"

  # Inspect stock MiuiCamera package version (streaming, multi-arg dumpsys)
  _cs_ver=""
  if [ -n "${CORESURFACE_DUMPSYS_CAMERA_PKG:-}" ] && [ -r "${CORESURFACE_DUMPSYS_CAMERA_PKG}" ]; then
    _cs_ver=$(awk '/versionName=/ { sub(/^.*versionName=/, ""); sub(/[[:space:]].*$/, ""); print; exit }' "$CORESURFACE_DUMPSYS_CAMERA_PKG" 2>/dev/null | tr -d '\r')
  else
    _cs_ver=$(_cs_cam_dumpsys package com.android.camera | awk '/versionName=/ { sub(/^.*versionName=/, ""); sub(/[[:space:]].*$/, ""); print; exit }' 2>/dev/null | tr -d '\r')
  fi
  [ -n "$_cs_ver" ] && CS_CAM_APK_VERSION="$_cs_ver"

  # Inspect real Camera2 HAL capabilities via streaming dumpsys media.camera
  CS_CAM_HAL_LEVEL="UNKNOWN"
  CS_CAM_HAS_RAW="0"
  CS_CAM_HAS_MANUAL="0"
  CS_CAM_HAS_10BIT="0"
  CS_CAM_HAS_4K60="0"
  CS_CAM_HAS_LOGICAL_MULTI="0"
  CS_CAM_LENS_COUNT="0"
  CS_CAM_PROBED="0"

  _cs_parsed=""
  if [ -n "${CORESURFACE_DUMPSYS_CAMERA:-}" ] && [ -r "${CORESURFACE_DUMPSYS_CAMERA}" ]; then
    _cs_parsed=$(_cs_cam_parse_media_stream < "$CORESURFACE_DUMPSYS_CAMERA")
  else
    _cs_parsed=$(_cs_cam_dumpsys media.camera | _cs_cam_parse_media_stream)
  fi

  if [ -n "$_cs_parsed" ]; then
    _cs_old_ifs=$IFS
    IFS='|'
    # shellcheck disable=SC2086
    set -- $_cs_parsed
    IFS=$_cs_old_ifs
    CS_CAM_HAL_LEVEL="${1:-UNKNOWN}"
    CS_CAM_HAS_RAW="${2:-0}"
    CS_CAM_HAS_MANUAL="${3:-0}"
    CS_CAM_HAS_10BIT="${4:-0}"
    CS_CAM_HAS_4K60="${5:-0}"
    CS_CAM_HAS_LOGICAL_MULTI="${6:-0}"
    CS_CAM_LENS_COUNT="${7:-0}"
    CS_CAM_PROBED="1"
  fi

  if [ "$_cs_was_probed" != "1" ] && [ "$CS_CAM_PROBED" = "1" ]; then
    CS_CAM_NEWLY_PROBED="1"
    export CS_CAM_NEWLY_PROBED
  fi

  # Determine honest Leica source (Native Flagship > Verified Companion > None)
  if [ "$CS_CAM_STOCK_HAS_LEICA" = "1" ]; then
    CS_CAM_LEICA_SOURCE="native"
  elif [ -n "$CS_CAM_COMPANION_ID" ]; then
    CS_CAM_LEICA_SOURCE="companion"
  else
    CS_CAM_LEICA_SOURCE="none"
  fi

  _cs_ctmp="${CS_CAM_CAPS_FILE}.tmp.$$"
  {
    printf 'CAM_SNAP_ID=%s\n' "$_cs_cp_id"
    printf 'CAM_PROBED=%s\n' "$CS_CAM_PROBED"
    printf 'CAM_ISP=%s\n' "$CS_CAM_ISP"
    printf 'CAM_HAL_LEVEL=%s\n' "$CS_CAM_HAL_LEVEL"
    printf 'CAM_HAS_RAW=%s\n' "$CS_CAM_HAS_RAW"
    printf 'CAM_HAS_MANUAL=%s\n' "$CS_CAM_HAS_MANUAL"
    printf 'CAM_HAS_10BIT=%s\n' "$CS_CAM_HAS_10BIT"
    printf 'CAM_HAS_4K60=%s\n' "$CS_CAM_HAS_4K60"
    printf 'CAM_HAS_LOGICAL_MULTI=%s\n' "$CS_CAM_HAS_LOGICAL_MULTI"
    printf 'CAM_LENS_COUNT=%s\n' "$CS_CAM_LENS_COUNT"
    printf 'CAM_APK_VERSION=%s\n' "$CS_CAM_APK_VERSION"
    printf 'CAM_STOCK_HAS_LEICA=%s\n' "$CS_CAM_STOCK_HAS_LEICA"
    printf 'CAM_LEICA_SOURCE=%s\n' "$CS_CAM_LEICA_SOURCE"
    printf 'CAM_COMPANION_ID=%s\n' "$CS_CAM_COMPANION_ID"
    printf 'CAM_COMPANION_NAME=%s\n' "$CS_CAM_COMPANION_NAME"
  } > "$_cs_ctmp" && mv -f "$_cs_ctmp" "$CS_CAM_CAPS_FILE"

  cs_log "Camera Probe: HAL=${CS_CAM_HAL_LEVEL} ISP=${CS_CAM_ISP} Lenses=${CS_CAM_LENS_COUNT} RAW=${CS_CAM_HAS_RAW} Manual=${CS_CAM_HAS_MANUAL} 4K60=${CS_CAM_HAS_4K60} 10bit=${CS_CAM_HAS_10BIT} Leica=${CS_CAM_LEICA_SOURCE} APK=${CS_CAM_APK_VERSION}."
  return 0
}

# Helper: returns 0 if Camera2 HAL is FULL or LEVEL_3
cs_camera_hal_is_full() {
  case "${CS_CAM_HAL_LEVEL:-UNKNOWN}" in
    FULL|LEVEL_3) return 0 ;;
    *) return 1 ;;
  esac
}

# Helper: returns 0 if RAM & Tier permit Parallel Processing safely (never on Lite / <= 4GB)
cs_camera_allow_parallel() {
  [ "${CS_EFF_TIER:-low}" != "low" ] && [ "${CS_RAM_MB:-0}" -ge 5500 ]
}

# Helper: count how many hardware-verified Camera Pro capabilities are eligible on this device
cs_camera_pro_cap_count() {
  _cc_cnt=1 # Universal safe utilities (shutter toggle / document mode / quick snap / AI watermark)
  if [ "${CS_CAM_HAS_MANUAL:-0}" = "1" ] || cs_camera_hal_is_full; then
    _cc_cnt=$((_cc_cnt + 1))
  fi
  if [ "${CS_CAM_HAS_RAW:-0}" = "1" ] && cs_camera_hal_is_full; then
    _cc_cnt=$((_cc_cnt + 1))
  fi
  if [ "${CS_CAM_LENS_COUNT:-0}" -ge 2 ] || [ "${CS_CAM_HAS_LOGICAL_MULTI:-0}" = "1" ]; then
    _cc_cnt=$((_cc_cnt + 1))
  fi
  if [ "${CS_CAM_HAS_4K60:-0}" = "1" ]; then
    _cc_cnt=$((_cc_cnt + 1))
  fi
  if [ "${CS_CAM_HAS_10BIT:-0}" = "1" ]; then
    _cc_cnt=$((_cc_cnt + 1))
  fi
  if cs_camera_allow_parallel; then
    _cc_cnt=$((_cc_cnt + 1))
  fi
  printf '%s\n' "$_cc_cnt"
}

# Helper: human-readable list of genuinely unlocked Camera Pro Engine capabilities
cs_camera_active_unlocks_csv() {
  if [ "${CFG_FEAT_CAMERA_PRO:-auto}" = "0" ]; then
    printf 'Disabled\n'
    return 0
  fi
  if [ "${CS_CAM_LEICA_SOURCE:-none}" = "native" ] || [ "${CS_EFF_TIER:-low}" = "motion_only" ]; then
    printf 'Native Flagship Passthrough\n'
    return 0
  fi
  _cau_list="Pro Utilities"
  if [ "${CS_CAM_HAS_MANUAL:-0}" = "1" ] || cs_camera_hal_is_full; then
    _cau_list="${_cau_list}, Pro Aids + EIS"
  fi
  if [ "${CS_CAM_HAS_RAW:-0}" = "1" ] && cs_camera_hal_is_full; then
    _cau_list="${_cau_list}, True RAW/DNG"
  fi
  if [ "${CS_CAM_LENS_COUNT:-0}" -ge 2 ] || [ "${CS_CAM_HAS_LOGICAL_MULTI:-0}" = "1" ]; then
    _cau_list="${_cau_list}, Multi-Lens Bokeh"
  fi
  if [ "${CS_CAM_HAS_4K60:-0}" = "1" ]; then
    _cau_list="${_cau_list}, 4K@60"
  fi
  if [ "${CS_CAM_HAS_10BIT:-0}" = "1" ]; then
    _cau_list="${_cau_list}, 10-bit HDR"
  fi
  if cs_camera_allow_parallel; then
    _cau_list="${_cau_list}, Parallel Process"
  fi
  printf '%s\n' "$_cau_list"
}

# Helper: deterministic Leica Companion Readiness signature (for Track 2 compatibility matching)
cs_camera_readiness_profile() {
  _crp_isp=$(printf '%s' "${CS_CAM_ISP:-generic}" | tr '[:lower:]' '[:upper:]')
  _crp_apk=${CS_CAM_APK_VERSION:-unknown}
  printf 'HOS%s-SDK%s-%s-HAL_%s-CAM_%s\n' \
    "${CS_HYPEROS_MAJOR:-0}" "${CS_ANDROID_SDK:-0}" "$_crp_isp" \
    "${CS_CAM_HAL_LEVEL:-UNKNOWN}" "$_crp_apk"
}

# Helper: atomically update a key in config.prop (self-contained for service.sh & webui_ctl.sh)
_cs_cam_write_cfg_key() {
  _cwk_file=$1
  _cwk_key=$2
  _cwk_val=$3
  [ -n "$_cwk_file" ] || return 1
  _cwk_tmp="${_cwk_file}.tmp.$$"
  if [ -r "$_cwk_file" ]; then
    awk -F '=' -v k="$_cwk_key" '$1 != k { print $0 }' "$_cwk_file" > "$_cwk_tmp"
  else
    : > "$_cwk_tmp"
  fi
  printf '%s=%s\n' "$_cwk_key" "$_cwk_val" >> "$_cwk_tmp"
  mv -f "$_cwk_tmp" "$_cwk_file"
}

# On-Boot & On-Demand Camera Anti-Crash Inspector (0 KB Background Daemon)
# Inspects crash buffer for repeated com.android.camera crashes (>= 2).
# If crash loop detected while Leica Bridge/Companion is active -> auto-reverts fail-closed.
# Preserves auto_reverted / reverted_by_user status across hot-sync until a clean reboot.
cs_camera_crash_inspect() {
  _cs_ci_cfg=${1:-${CS_STATE_DIR}/config.prop}
  cs_watchdog_init_dir || return 0
  cs_camera_load_caps
  _cs_prev_wd_status="$CS_CAM_WATCHDOG_STATUS"
  _cs_prev_wd_reason="$CS_CAM_WATCHDOG_REASON"

  CS_CAM_CRASH_COUNT="0"
  if [ -n "${CORESURFACE_CAMERA_CRASH_LOG:-}" ] && [ -r "${CORESURFACE_CAMERA_CRASH_LOG}" ]; then
    CS_CAM_CRASH_COUNT=$(awk '
      /Process:[[:space:]]*com\.android\.camera/ || /FATAL EXCEPTION.*com\.android\.camera/ || />>> com\.android\.camera <<</ {
        c++
      }
      END { printf "%d\n", c + 0 }
    ' "$CORESURFACE_CAMERA_CRASH_LOG" 2>/dev/null || printf '0\n')
  elif command -v logcat >/dev/null 2>&1; then
    CS_CAM_CRASH_COUNT=$(_cs_cam_timeout_run 4 logcat -d -b crash -t 250 2>/dev/null | awk '
      /Process:[[:space:]]*com\.android\.camera/ || /FATAL EXCEPTION.*com\.android\.camera/ || />>> com\.android\.camera <<</ {
        c++
      }
      END { printf "%d\n", c + 0 }
    ' 2>/dev/null || printf '0\n')
  fi

  if [ "$CS_CAM_PROBED" = "1" ] && [ "$CS_CAM_HAL_LEVEL" != "UNKNOWN" ]; then
    CS_CAM_SERVICE_HEALTH="ok"
  else
    CS_CAM_SERVICE_HEALTH="unknown"
  fi

  CS_CAM_WATCHDOG_STATUS="healthy"
  CS_CAM_WATCHDOG_REASON="none"

  if [ "${CS_CAM_CRASH_COUNT:-0}" -ge 2 ]; then
    if [ "${EFF_FEAT_LEICA_BRIDGE:-0}" = "1" ] || [ "$CS_CAM_LEICA_SOURCE" = "companion" ]; then
      _cs_cam_write_cfg_key "$_cs_ci_cfg" "FEAT_LEICA_BRIDGE" "0" || true
      CFG_FEAT_LEICA_BRIDGE="0"
      EFF_FEAT_LEICA_BRIDGE="0"
      export CFG_FEAT_LEICA_BRIDGE EFF_FEAT_LEICA_BRIDGE

      _cs_mods_dir=${CORESURFACE_MODULES_DIR:-/data/adb/modules}
      if [ -n "$CS_CAM_COMPANION_ID" ] && [ -d "${_cs_mods_dir}/${CS_CAM_COMPANION_ID}" ]; then
        : > "${_cs_mods_dir}/${CS_CAM_COMPANION_ID}/disable" 2>/dev/null || true
      fi

      CS_CAM_WATCHDOG_STATUS="auto_reverted"
      CS_CAM_WATCHDOG_REASON="camera_crash_loop_${CS_CAM_CRASH_COUNT}x_${CS_CAM_ISP}_sdk${CS_ANDROID_SDK:-0}"
      cs_log "Camera Watchdog: detected ${CS_CAM_CRASH_COUNT} crashes in com.android.camera — auto-reverted Leica Bridge & disabled companion (${CS_CAM_COMPANION_ID:-none}) to protect Stock Camera + Pro Engine."
    elif [ "$_cs_prev_wd_status" = "auto_reverted" ] || [ "$_cs_prev_wd_status" = "reverted_by_user" ]; then
      # Preserve revert notice across hot-sync within the same boot session so WebUI banner remains visible
      CS_CAM_WATCHDOG_STATUS="$_cs_prev_wd_status"
      CS_CAM_WATCHDOG_REASON="$_cs_prev_wd_reason"
    else
      CS_CAM_WATCHDOG_STATUS="warning"
      CS_CAM_WATCHDOG_REASON="stock_camera_crashes_${CS_CAM_CRASH_COUNT}x"
      cs_log "Camera Watchdog: observed ${CS_CAM_CRASH_COUNT} crashes in com.android.camera (Leica Bridge inactive)."
    fi
  elif [ "${CS_CAM_CRASH_COUNT:-0}" -eq 1 ]; then
    if [ "$_cs_prev_wd_status" = "auto_reverted" ] || [ "$_cs_prev_wd_status" = "reverted_by_user" ]; then
      CS_CAM_WATCHDOG_STATUS="$_cs_prev_wd_status"
      CS_CAM_WATCHDOG_REASON="$_cs_prev_wd_reason"
    else
      CS_CAM_WATCHDOG_STATUS="warning"
      CS_CAM_WATCHDOG_REASON="single_camera_crash_observed"
    fi
  fi

  _cs_wtmp="${CS_CAM_WATCHDOG_FILE}.tmp.$$"
  {
    printf 'CAM_CRASH_COUNT=%s\n' "$CS_CAM_CRASH_COUNT"
    printf 'CAM_WATCHDOG_STATUS=%s\n' "$CS_CAM_WATCHDOG_STATUS"
    printf 'CAM_WATCHDOG_REASON=%s\n' "$CS_CAM_WATCHDOG_REASON"
    printf 'CAM_SERVICE_HEALTH=%s\n' "$CS_CAM_SERVICE_HEALTH"
  } > "$_cs_wtmp" && mv -f "$_cs_wtmp" "$CS_CAM_WATCHDOG_FILE"

  return 0
}

# Explicit 1-tap Safe Rollback from WebUI/CLI (disables Leica Bridge + any companion module)
cs_camera_safe_rollback() {
  _cs_cr_cfg=${1:-${CS_STATE_DIR}/config.prop}
  cs_watchdog_init_dir || return 1
  cs_camera_load_caps

  _cs_cam_write_cfg_key "$_cs_cr_cfg" "FEAT_LEICA_BRIDGE" "0" || return 1
  CFG_FEAT_LEICA_BRIDGE="0"
  EFF_FEAT_LEICA_BRIDGE="0"
  export CFG_FEAT_LEICA_BRIDGE EFF_FEAT_LEICA_BRIDGE

  _cs_mods_dir=${CORESURFACE_MODULES_DIR:-/data/adb/modules}
  _cs_cr_comp_msg="none"
  if [ -n "$CS_CAM_COMPANION_ID" ] && [ -d "${_cs_mods_dir}/${CS_CAM_COMPANION_ID}" ]; then
    : > "${_cs_mods_dir}/${CS_CAM_COMPANION_ID}/disable" 2>/dev/null || true
    _cs_cr_comp_msg="$CS_CAM_COMPANION_ID"
  fi

  CS_CAM_WATCHDOG_STATUS="reverted_by_user"
  CS_CAM_WATCHDOG_REASON="manual_safe_rollback"
  _cs_wtmp="${CS_CAM_WATCHDOG_FILE}.tmp.$$"
  {
    printf 'CAM_CRASH_COUNT=%s\n' "${CS_CAM_CRASH_COUNT:-0}"
    printf 'CAM_WATCHDOG_STATUS=%s\n' "$CS_CAM_WATCHDOG_STATUS"
    printf 'CAM_WATCHDOG_REASON=%s\n' "$CS_CAM_WATCHDOG_REASON"
    printf 'CAM_SERVICE_HEALTH=%s\n' "${CS_CAM_SERVICE_HEALTH:-unknown}"
  } > "$_cs_wtmp" && mv -f "$_cs_wtmp" "$CS_CAM_WATCHDOG_FILE"

  cs_log "Camera Safe Rollback: disabled FEAT_LEICA_BRIDGE and companion (${_cs_cr_comp_msg}); Stock Camera + Pro Engine preserved."
  printf 'Camera Safe Rollback applied (companion disabled: %s). Reboot once to restore stock camera.\n' "$_cs_cr_comp_msg"
}
