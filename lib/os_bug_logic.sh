#!/system/bin/sh
# CoreSurface - Device Logic & OS/System Bug Detector (Pure POSIX sh)
# Dynamically detects real HyperOS / Android OS bugs & hardware quirks at runtime
# (zero hardcoded device codenames) and reports honest mitigations to os_bugs.state.

CS_OS_BUGS_FILE="$CS_STATE_DIR/os_bugs.state"

cs_bug_append_csv() {
  _cs_ba_cur=$1
  _cs_ba_item=$2
  if [ -z "$_cs_ba_cur" ]; then
    printf '%s' "$_cs_ba_item"
  else
    printf '%s,%s' "$_cs_ba_cur" "$_cs_ba_item"
  fi
}

# Scan runtime OS/ROM/hardware environment for known HyperOS & Android bugs.
# Argument $1: stage ("early" during post-fs-data | "late" during service/webui)
# Argument $2: optional MODDIR for post-boot overlayfs mount check
cs_os_bug_scan() {
  _cs_stage=${1:-late}
  _cs_moddir=${2:-}

  cs_watchdog_init_dir || return 0

  CS_OS_BUGS_DETECTED=0
  CS_OS_BUGS_MITIGATED=0
  CS_OS_BUGS_CSV=""
  _cs_mounts=${CORESURFACE_PROC_MOUNTS:-/proc/mounts}
  _cs_live_ov_dir=${CORESURFACE_LIVE_OVERLAY_DIR:-/product/overlay}

  # 1. HyperOS 3+ non-flagship Advanced Textures Toast & Recent Apps breakage
  if [ "${CS_HYPEROS_MAJOR:-0}" -ge 3 ] && [ "${CS_STOCK_DEVICE_LEVEL:-0}" -lt 3 ]; then
    CS_OS_BUGS_DETECTED=$((CS_OS_BUGS_DETECTED + 1))
    CS_OS_BUGS_MITIGATED=$((CS_OS_BUGS_MITIGATED + 1))
    CS_OS_BUGS_CSV=$(cs_bug_append_csv "$CS_OS_BUGS_CSV" "HOS3_ADVTEX_TOAST_RECENTS")
  fi

  # 2. HyperOS 3+ mFullAodHideEase / support_aod_fullscreen crash risk
  if [ "${CS_HYPEROS_MAJOR:-0}" -ge 3 ]; then
    CS_OS_BUGS_DETECTED=$((CS_OS_BUGS_DETECTED + 1))
    CS_OS_BUGS_MITIGATED=$((CS_OS_BUGS_MITIGATED + 1))
    CS_OS_BUGS_CSV=$(cs_bug_append_csv "$CS_OS_BUGS_CSV" "HOS3_AOD_FULLSCREEN_CRASH")
  fi

  # 3. Android 15/16 (SDK >= 35) KernelSU root Binder rejection on settings/cmd/pm
  if [ "${CS_ANDROID_SDK:-0}" -ge 35 ]; then
    CS_OS_BUGS_DETECTED=$((CS_OS_BUGS_DETECTED + 1))
    CS_OS_BUGS_MITIGATED=$((CS_OS_BUGS_MITIGATED + 1))
    CS_OS_BUGS_CSV=$(cs_bug_append_csv "$CS_OS_BUGS_CSV" "SDK35_ROOT_BINDER_GUARD")
  fi

  # 4. Soft-reboot stale XML bind-mount detection (checked during early boot before mount)
  if [ "$_cs_stage" = "early" ]; then
    if [ "${CS_STALE_XML_DETECTED:-0}" = "1" ] || { [ -r "$_cs_mounts" ] && grep -q '/device_features/.*\.xml ' "$_cs_mounts" 2>/dev/null; }; then
      CS_OS_BUGS_DETECTED=$((CS_OS_BUGS_DETECTED + 1))
      CS_OS_BUGS_MITIGATED=$((CS_OS_BUGS_MITIGATED + 1))
      CS_OS_BUGS_CSV=$(cs_bug_append_csv "$CS_OS_BUGS_CSV" "SOFT_REBOOT_STALE_XML")
    fi
  fi

  # 5. Non-LTPO AMOLED 10-second AOD timeout cap on non-flagship devices
  if [ "${CS_STOCK_DEVICE_LEVEL:-0}" -lt 3 ] && [ "${CS_EFF_TIER:-low}" != "motion_only" ]; then
    CS_OS_BUGS_DETECTED=$((CS_OS_BUGS_DETECTED + 1))
    if [ "${EFF_FEAT_AOD_UNLOCK:-0}" = "1" ]; then
      CS_OS_BUGS_MITIGATED=$((CS_OS_BUGS_MITIGATED + 1))
    fi
    CS_OS_BUGS_CSV=$(cs_bug_append_csv "$CS_OS_BUGS_CSV" "NON_LTPO_AOD_10S_CAP")
  fi

  # 6. Vendor blur/low-RAM throttle (blurs_are_expensive=1 or low_ram=true)
  _cs_sf_exp=$(cs_getprop "ro.sf.blurs_are_expensive")
  _cs_low_ram=$(cs_getprop "ro.config.low_ram")
  if [ "$_cs_sf_exp" = "1" ] || [ "$_cs_low_ram" = "true" ] || [ "${CS_STOCK_BLURS_EXPENSIVE:-0}" = "1" ] || [ "${CS_STOCK_LOW_RAM:-0}" = "1" ]; then
    CS_OS_BUGS_DETECTED=$((CS_OS_BUGS_DETECTED + 1))
    if [ "${EFF_FEAT_BLUR:-0}" = "1" ] || [ "${EFF_FEAT_MULTITASK:-0}" = "1" ]; then
      CS_OS_BUGS_MITIGATED=$((CS_OS_BUGS_MITIGATED + 1))
    fi
    CS_OS_BUGS_CSV=$(cs_bug_append_csv "$CS_OS_BUGS_CSV" "VENDOR_BLUR_LOWRAM_THROTTLE")
  fi

  # 7. Leaked persist.* props from legacy/third-party modules on HyperOS 3+
  if [ "${CS_HYPEROS_MAJOR:-0}" -ge 3 ]; then
    _cs_leak_avr=$(cs_getprop "persist.sys.advanced_visual_release")
    if [ -n "$_cs_leak_avr" ]; then
      CS_OS_BUGS_DETECTED=$((CS_OS_BUGS_DETECTED + 1))
      CS_OS_BUGS_MITIGATED=$((CS_OS_BUGS_MITIGATED + 1))
      CS_OS_BUGS_CSV=$(cs_bug_append_csv "$CS_OS_BUGS_CSV" "LEAKED_PERSIST_PROPS")
    fi
  fi

  # 8. Post-boot check: staged RRO APKs missing in /product/overlay (missing meta-overlayfs)
  if [ "$_cs_stage" = "late" ] && [ "${EFF_FEAT_RRO_OVERLAYS:-0}" = "1" ] && [ -n "$_cs_moddir" ]; then
    _cs_staged_dir="$_cs_moddir/system/product/overlay"
    if [ -d "$_cs_staged_dir" ]; then
      _cs_has_staged=0
      _cs_any_live=0
      for _cs_ov_f in "$_cs_staged_dir"/CoreSurface*.apk; do
        [ -e "$_cs_ov_f" ] || break
        _cs_has_staged=1
        _cs_ov_base=$(basename "$_cs_ov_f")
        if [ -f "$_cs_live_ov_dir/$_cs_ov_base" ]; then
          _cs_any_live=1
          break
        fi
      done
      if [ "$_cs_has_staged" -eq 1 ] && [ "$_cs_any_live" -eq 0 ]; then
        CS_OS_BUGS_DETECTED=$((CS_OS_BUGS_DETECTED + 1))
        CS_OS_BUGS_CSV=$(cs_bug_append_csv "$CS_OS_BUGS_CSV" "MISSING_META_OVERLAYFS")
      fi
    fi
  fi

  _cs_tmp="$CS_OS_BUGS_FILE.tmp.$$"
  {
    printf 'OS_BUGS_DETECTED=%s\n' "$CS_OS_BUGS_DETECTED"
    printf 'OS_BUGS_MITIGATED=%s\n' "$CS_OS_BUGS_MITIGATED"
    printf 'OS_BUGS_CSV=%s\n' "$CS_OS_BUGS_CSV"
  } > "$_cs_tmp"
  mv -f "$_cs_tmp" "$CS_OS_BUGS_FILE"

  export CS_OS_BUGS_DETECTED CS_OS_BUGS_MITIGATED CS_OS_BUGS_CSV
  cs_log "Device Logic (${_cs_stage}): detected ${CS_OS_BUGS_DETECTED} OS/system quirk(s), auto-mitigated ${CS_OS_BUGS_MITIGATED} [${CS_OS_BUGS_CSV:-none}]."
  return 0
}
