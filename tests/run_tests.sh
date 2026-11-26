#!/bin/sh
# CoreSurface v1.0.0 - Host Unit Test Suite (Pure POSIX sh)
# Mocks getprop, resetprop, pidof, sleep, mount, settings, /proc/meminfo, and /proc/mounts.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP_BASE=$(mktemp -d)
trap 'rm -rf "$TMP_BASE"' EXIT INT TERM

PASS_COUNT=0
FAIL_COUNT=0

fail() {
  printf '  [FAIL] %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf '  [PASS] %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_eq() {
  _actual=$1
  _expected=$2
  _label=$3
  if [ "$_actual" = "$_expected" ]; then
    pass "$_label"
  else
    fail "${_label} (expected='${_expected}', actual='${_actual}')"
  fi
}

assert_file_contains() {
  _file=$1
  _pattern=$2
  _label=$3
  if [ -r "$_file" ] && grep -F -q -- "$_pattern" "$_file"; then
    pass "$_label"
  else
    fail "${_label} (missing '${_pattern}' in ${_file})"
  fi
}

assert_file_not_contains() {
  _file=$1
  _pattern=$2
  _label=$3
  if [ ! -r "$_file" ] || ! grep -F -q -- "$_pattern" "$_file"; then
    pass "$_label"
  else
    fail "${_label} (unexpected '${_pattern}' found in ${_file})"
  fi
}

# Create a fresh isolated test environment with mock binaries.
setup_sandbox() {
  _name=$1
  SB="$TMP_BASE/$_name"
  SB_BIN="$SB/bin"
  SB_MOD="$SB/mod"
  SB_STATE="$SB/state"
  SB_PROPS_LOG="$SB/resetprop.calls"
  SB_PROPS_DB="$SB/live_props.db"
  SB_MOUNT_LOG="$SB/mount.calls"
  SB_CHCON_LOG="$SB/chcon.calls"
  SB_PROC_MOUNTS="$SB/proc_mounts"
  SB_SETTINGS_DB="$SB/settings.db"
  SB_SETTINGS_LOG="$SB/settings.calls"
  SB_MEMINFO="$SB/meminfo"
  SB_XML_DIR1="$SB/xml_dir1"
  SB_XML_DIR2="$SB/xml_dir2"
  SB_CF_DIR="$SB/cfae_framework"

  mkdir -p "$SB_BIN" "$SB_MOD" "$SB_STATE" "$SB_XML_DIR1" "$SB_XML_DIR2"
  : > "$SB_PROPS_LOG"
  : > "$SB_PROPS_DB"
  : > "$SB_MOUNT_LOG"
  : > "$SB_CHCON_LOG"
  : > "$SB_PROC_MOUNTS"
  : > "$SB_SETTINGS_DB"
  : > "$SB_SETTINGS_LOG"

  cp -R "$REPO_ROOT/lib" "$REPO_ROOT/defaults" "$REPO_ROOT/post-fs-data.sh" "$REPO_ROOT/service.sh" "$REPO_ROOT/action.sh" "$REPO_ROOT/uninstall.sh" "$SB_MOD/"

  # Fast no-op sleep mock
  cat > "$SB_BIN/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$SB_BIN/sleep"

  # chcon mock to verify SELinux context restoration before bind-mount
  cat > "$SB_BIN/chcon" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SB_CHCON_LOG"
exit 0
EOF
  chmod +x "$SB_BIN/chcon"

  # Strict resetprop mock:
  # - Permits `-p -d <key>` exclusively for one-time leaked persist.* cleanup
  # - MUST receive `-n` for every property write (never writes /data/property)
  cat > "$SB_BIN/resetprop" <<EOF
#!/bin/sh
if [ "\${1:-}" = "-p" ] && [ "\${2:-}" = "-d" ]; then
  printf 'PURGED:%s\n' "\${3:-}" >> "$SB_PROPS_LOG"
  exit 0
fi
if [ "\${1:-}" != "-n" ]; then
  printf 'NON_PERSIST_VIOLATION:%s\n' "\$*" >> "$SB_PROPS_LOG"
  exit 99
fi
shift
k=\${1:-}
v=\${2:-}
printf '%s=%s\n' "\$k" "\$v" >> "$SB_PROPS_LOG"
tmp="$SB_PROPS_DB.tmp.\$\$"
awk -F '=' -v key="\$k" '\$1 != key { print \$0 }' "$SB_PROPS_DB" > "\$tmp" 2>/dev/null || : > "\$tmp"
printf '%s=%s\n' "\$k" "\$v" >> "\$tmp"
mv -f "\$tmp" "$SB_PROPS_DB"
exit 0
EOF
  chmod +x "$SB_BIN/resetprop"

  # Mount mock: records bind mounts and appends to mock /proc/mounts
  cat > "$SB_BIN/mount" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--bind" ]; then
  printf '%s -> %s\n' "\${2:-}" "\${3:-}" >> "$SB_MOUNT_LOG"
  printf '%s %s ext4 ro,relatime 0 0\n' "\${2:-}" "\${3:-}" >> "$SB_PROC_MOUNTS"
  exit 0
fi
exit 1
EOF
  chmod +x "$SB_BIN/mount"

  # Transactional settings mock supporting --user 0 (Android 16 / SDK 36)
  cat > "$SB_BIN/settings" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SB_SETTINGS_LOG"
if [ "\${1:-}" = "--user" ]; then
  shift 2
fi
cmd=\${1:-}
ns=\${2:-}
key=\${3:-}
val=\${4:-}
id="\${ns}|\${key}"
case "\$cmd" in
  get)
    out=\$(awk -F '=' -v id="\$id" '\$1 == id { sub(/^[^=]*=/, ""); print; exit }' "$SB_SETTINGS_DB" 2>/dev/null || true)
    if [ -z "\$out" ]; then
      printf 'null\n'
    else
      printf '%s\n' "\$out"
    fi
    ;;
  put)
    tmp="$SB_SETTINGS_DB.tmp.\$\$"
    awk -F '=' -v id="\$id" '\$1 != id { print \$0 }' "$SB_SETTINGS_DB" > "\$tmp" 2>/dev/null || : > "\$tmp"
    printf '%s=%s\n' "\$id" "\$val" >> "\$tmp"
    mv -f "\$tmp" "$SB_SETTINGS_DB"
    ;;
  delete)
    tmp="$SB_SETTINGS_DB.tmp.\$\$"
    awk -F '=' -v id="\$id" '\$1 != id { print \$0 }' "$SB_SETTINGS_DB" > "\$tmp" 2>/dev/null || : > "\$tmp"
    mv -f "\$tmp" "$SB_SETTINGS_DB"
    ;;
  *) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$SB_BIN/settings"
}

write_mock_getprop() {
  _hos=$1
  _miui=$2
  _sdk=$3
  _boot=${4:-1}
  _dev=${5:-testdevice}
  _mkt=${6:-}
  cat > "$SB_BIN/getprop" <<EOF
#!/bin/sh
k=\${1:-}
case "\$k" in
  ro.mi.os.version.name) printf '%s\n' "$_hos" ; exit 0 ;;
  ro.miui.ui.version.name) printf '%s\n' "$_miui" ; exit 0 ;;
  ro.build.version.sdk) printf '%s\n' "$_sdk" ; exit 0 ;;
  sys.boot_completed) printf '%s\n' "$_boot" ; exit 0 ;;
  ro.product.device) printf '%s\n' "$_dev" ; exit 0 ;;
  ro.product.marketname) printf '%s\n' "$_mkt" ; exit 0 ;;
esac
awk -F '=' -v key="\$k" '\$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$SB_PROPS_DB" 2>/dev/null || true
EOF
  chmod +x "$SB_BIN/getprop"
}

write_mock_meminfo() {
  _kb=$1
  printf 'MemTotal:       %s kB\nMemFree:        1024000 kB\n' "$_kb" > "$SB_MEMINFO"
}

write_sample_xml() {
  _path=$1
  cat > "$_path" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<features>
    <bool name="support_background_blur">false</bool>
    <integer name="device_level">1</integer>
    <bool name="support_aod">false</bool>
    <bool name="support_screen_effect">true</bool>
    <bool name="support_double_tap_to_wake">true</bool>
    <integer-array name="fpsList">
        <item>120</item>
        <item>60</item>
    </integer-array>
</features>
EOF
}

run_post_fs_data() {
  PATH="$SB_BIN:$PATH" \
  CORESURFACE_MODDIR="$SB_MOD" \
  CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" \
  CORESURFACE_PROC_MOUNTS="$SB_PROC_MOUNTS" \
  CORESURFACE_XML_SEARCH_DIRS="$SB_XML_DIR1:$SB_XML_DIR2" \
  sh "$SB_MOD/post-fs-data.sh"
}

run_service() {
  PATH="$SB_BIN:$PATH" \
  CORESURFACE_MODDIR="$SB_MOD" \
  CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" \
  CORESURFACE_PROC_MOUNTS="$SB_PROC_MOUNTS" \
  CORESURFACE_BOOT_TIMEOUT=6 \
  CORESURFACE_SYSUI_WAIT=6 \
  CORESURFACE_HEALTH_SECONDS=6 \
  CORESURFACE_POLL_INTERVAL=2 \
  sh "$SB_MOD/service.sh"
}

# ---------------------------------------------------------------------------
printf '=== Test 1: Non-HyperOS/MIUI ROM Gate ===\n'
setup_sandbox "t1_non_hyperos"
write_mock_getprop "" "" "35" "1"
write_mock_meminfo "8000000"
run_post_fs_data
_rc=$?
assert_eq "$_rc" "0" "Non-HyperOS post-fs-data exits 0"
assert_eq "$(wc -l < "$SB_PROPS_LOG" | tr -d ' ')" "0" "Non-HyperOS writes zero properties"
assert_file_contains "$SB_STATE/state.prop" "WATCHDOG_STATUS=unsupported_rom" "State records unsupported_rom"
assert_eq "$( [ -f "$SB_STATE/boot_strikes" ] && printf 'exists' || printf 'absent' )" "absent" "Non-HyperOS does not increment boot_strikes"

# ---------------------------------------------------------------------------
printf '=== Test 2: Watchdog Auto-Disable on Strike 2 (Fail-Closed) ===\n'
setup_sandbox "t2_watchdog_strike"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "8000000"

run_post_fs_data
assert_eq "$(cat "$SB_STATE/boot_strikes")" "1" "Boot 1 increments boot_strikes to 1"
assert_eq "$( [ -f "$SB_MOD/disable" ] && printf 'yes' || printf 'no' )" "no" "Module still enabled after strike 1"

run_post_fs_data
assert_eq "$(cat "$SB_STATE/boot_strikes")" "2" "Boot 2 increments boot_strikes to 2"

: > "$SB_PROPS_LOG"
: > "$SB_MOUNT_LOG"
run_post_fs_data
_rc=$?
assert_eq "$_rc" "0" "Strike >= 2 exits 0 cleanly"
assert_eq "$( [ -f "$SB_MOD/disable" ] && printf 'yes' || printf 'no' )" "yes" "Strike >= 2 creates disable file"
assert_eq "$(cat "$SB_STATE/boot_strikes")" "0" "Strike >= 2 resets boot_strikes to 0"
assert_eq "$(wc -l < "$SB_PROPS_LOG" | tr -d ' ')" "0" "Strike >= 2 applies zero properties"
assert_eq "$(wc -l < "$SB_MOUNT_LOG" | tr -d ' ')" "0" "Strike >= 2 skips XML bind-mount"
assert_file_contains "$SB_STATE/state.prop" "WATCHDOG_STATUS=safe_mode_disabled" "State records safe_mode_disabled"

# ---------------------------------------------------------------------------
printf '=== Test 3: Watchdog service.sh Grace Window + Stable SystemUI ===\n'
setup_sandbox "t3_sysui_grace_healthy"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "8000000"
run_post_fs_data

_pid_counter="$SB/pid_calls"
printf '0\n' > "$_pid_counter"
cat > "$SB_BIN/pidof" <<EOF
#!/bin/sh
c=\$(cat "$_pid_counter")
c=\$((c + 1))
printf '%s\n' "\$c" > "$_pid_counter"
if [ "\$c" -le 2 ]; then
  exit 1
fi
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

run_service
assert_eq "$(cat "$SB_STATE/boot_strikes")" "0" "Stable SystemUI after grace window resets boot_strikes to 0"
assert_file_contains "$SB_STATE/state.prop" "WATCHDOG_STATUS=healthy" "State records healthy"

# ---------------------------------------------------------------------------
printf '=== Test 4: Watchdog service.sh Detects SystemUI Crash ===\n'
setup_sandbox "t4_sysui_crash"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "8000000"
run_post_fs_data

_pid_counter="$SB/pid_calls"
printf '0\n' > "$_pid_counter"
cat > "$SB_BIN/pidof" <<EOF
#!/bin/sh
c=\$(cat "$_pid_counter")
c=\$((c + 1))
printf '%s\n' "\$c" > "$_pid_counter"
if [ "\$c" -le 2 ]; then
  printf '4242\n'
else
  printf '5151\n'
fi
exit 0
EOF
chmod +x "$SB_BIN/pidof"

run_service
assert_eq "$(cat "$SB_STATE/boot_strikes")" "1" "SystemUI PID change keeps boot_strikes=1"
assert_file_contains "$SB_STATE/state.prop" "WATCHDOG_STATUS=degraded" "State records degraded on PID change"

# ---------------------------------------------------------------------------
printf '=== Test 5: 4-Tier Hardware Classification (Non-Pro vs Pro/Pro+ vs Flagship) & resetprop -n ===\n'
# 5a: Mid-Range Non-Pro (Redmi Note 15 5G, 8GB) -> auto detects low (Blur ON, NO Advanced Textures)
setup_sandbox "t5_mid_non_pro"
write_mock_getprop "OS3.0" "" "36" "1" "middev" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
write_sample_xml "$SB_XML_DIR1/middev.xml"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "NON_PERSIST_VIOLATION" "Non-Pro: all resetprop calls use -n"
assert_file_contains "$SB_STATE/state.prop" "DETECTED_TIER=low" "Non-Pro 8GB Redmi Note 15 5G auto-detects low tier"
assert_file_contains "$SB_STATE/state.prop" "EFF_TIER=low" "Non-Pro effective tier is low"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.has_blur=1" "Low tier keeps standard blur enabled"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.background_blur_status_default=false" "Low tier keeps Advanced Textures OFF"
assert_file_not_contains "$SB_STATE/work/device_features.xml" "support_advanced_textures" "Low tier NEVER injects support_advanced_textures in XML"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_display_expert_mode">true</bool>' "Low tier includes Custom Color Expert mode"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.deviceLevelList=v:1,c:2,g:2" "Low tier uses light animation deviceLevelList"
assert_file_not_contains "$SB_PROPS_LOG" "ro.config.low_ram=false" "Low tier keeps heavy multitask flags OFF"

# 5b: Mid-Range Pro/Pro+ (Redmi Note 15 Pro+ 5G / POCO X8 Pro, 8GB) -> auto detects balanced_pro
setup_sandbox "t5_mid_pro"
write_mock_getprop "OS3.0" "" "36" "1" "prodev" "Redmi Note 15 Pro+ 5G"
write_mock_meminfo "7500000"
write_sample_xml "$SB_XML_DIR1/prodev.xml"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "NON_PERSIST_VIOLATION" "Mid Pro+: all resetprop calls use -n"
assert_file_contains "$SB_STATE/state.prop" "DETECTED_TIER=balanced_pro" "Redmi Note 15 Pro+ 5G auto-detects balanced_pro tier"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.deviceLevelList=v:1,c:2,g:3" "Balance Pro/Pro+ sets mid-pro deviceLevelList"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.hyper_transition=true" "Balance Pro/Pro+ enables HyperTransition"
assert_file_contains "$SB_PROPS_LOG" "ro.sf.blurs_are_expensive=0" "Balance Pro/Pro+ unlocks consistent SurfaceFlinger blur"
assert_file_contains "$SB_PROPS_LOG" "ro.config.low_ram=false" "Balance Pro/Pro+ enables multitask relaxation"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.support_high_refresh_rate=true" "Balance Pro/Pro+ enables high refresh rate flag"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_display_expert_mode">true</bool>' "Balance Pro/Pro+ includes Custom Color Expert"

# 5c: Flagship Tier (12GB RAM or explicit CS_TIER_MODE=flagship)
setup_sandbox "t5_flagship"
write_mock_getprop "OS2.0" "" "35" "1" "ultradev" "Xiaomi 15 Ultra"
write_mock_meminfo "11800000"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "NON_PERSIST_VIOLATION" "Flagship: all resetprop calls use -n"
assert_file_contains "$SB_STATE/state.prop" "DETECTED_TIER=flagship" "12GB Xiaomi 15 Ultra auto-detects flagship tier"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.device_level=3" "Flagship: sets device_level=3"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.deviceLevelList=v:1,c:3,g:3" "Flagship: sets c:3,g:3 deviceLevelList"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.hyper_transition=true" "Flagship: enables HyperTransition"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.enable_parallel_sweep=true" "Flagship: enables parallel sweep"
assert_file_contains "$SB_PROPS_LOG" "ro.sf.blurs_are_expensive=0" "Flagship: disables blurs_are_expensive throttle"
assert_file_not_contains "$SB_PROPS_LOG" "enable_blurs_on_windows=" "Flagship: omits enable_blurs_on_windows that bloats Toasts"
assert_file_contains "$SB_PROPS_LOG" "ro.config.low_ram=false" "Flagship: enables multitask relaxation"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.support_high_refresh_rate=true" "Flagship: enables high refresh rate"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.hyperai_enabled=true" "Zero-gimmick: never emits placebo hyperai prop"

# 5d: Genuine Native Flagship (stock XML already has device_level=3 + support_background_blur=true) -> motion_only passthrough
setup_sandbox "t5_native_flagship_passthrough"
write_mock_getprop "OS3.0" "" "36" "1" "xuanyuan" "Xiaomi 15 Ultra"
write_mock_meminfo "15600000"
mkdir -p "$SB_MOD/overlays"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceSystemUI.apk"
cat > "$SB_XML_DIR1/xuanyuan.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<features>
    <integer name="device_level">3</integer>
    <bool name="support_background_blur">true</bool>
    <bool name="support_display_expert_mode">true</bool>
</features>
EOF
run_post_fs_data
assert_file_contains "$SB_STATE/state.prop" "DETECTED_TIER=motion_only" "Genuine Native Flagship auto-detects motion_only passthrough"
assert_file_contains "$SB_STATE/state.prop" "EFF_TIER=motion_only" "Native Flagship effective tier is motion_only"
assert_file_contains "$SB_PROPS_DB" "debug.coresurface.cfg=motion=off;native=0;guard=1;thermallod=1;aod=0" "Native Flagship still syncs live Folme Motion IPC"
assert_file_not_contains "$SB_PROPS_LOG" "ro.miui.device_level=" "Native Flagship skips redundant device_level prop override"
assert_file_not_contains "$SB_PROPS_LOG" "ro.miui.has_blur=1" "Native Flagship skips redundant blur prop overrides"
assert_eq "$(wc -l < "$SB_MOUNT_LOG" | tr -d ' ')" "0" "Native Flagship skips XML bind-mount when factory XML already has expert color"
assert_eq "$( [ -d "$SB_MOD/system/product/overlay" ] && printf 'exists' || printf 'cleared' )" "cleared" "Native Flagship skips staging RRO overlays"

# ---------------------------------------------------------------------------
printf '=== Test 6: Dynamic device_features XML Patcher (Non-Destructive, SELinux, Fail-Closed) ===\n'
# 6a: Runtime ro.product.device auto-discovery + non-destructive patch + SELinux + bind-mount
setup_sandbox "t6_xml_happy"
write_mock_getprop "OS2.0" "" "35" "1" "aurora"
write_mock_meminfo "11800000"
write_sample_xml "$SB_XML_DIR2/aurora.xml"
printf 'CS_TIER_MODE=flagship\nFEAT_AOD_UNLOCK=0\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_contains "$SB_STATE/state.prop" "XML_STATUS=mounted" "XML patcher mounts discovered runtime device XML"
assert_file_contains "$SB_STATE/state.prop" "XML_SOURCE=$SB_XML_DIR2/aurora.xml" "XML patcher records exact discovered source path"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_background_blur">true</bool>' "XML patcher upgrades <bool> false -> true"
assert_file_contains "$SB_STATE/work/device_features.xml" '<integer name="device_level">3</integer>' "XML patcher upgrades lower <integer> 1 -> 3 in flagship tier"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_display_expert_mode">true</bool>' "XML patcher enables Custom Color Expert across all modes"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_aod">false</bool>' "XML patcher does NOT touch AOD tag when FEAT_AOD_UNLOCK=0"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="gallery_support_video_compress">true</bool>' "Flagship Suite XML enables verified Gallery video compress"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_screen_effect">true</bool>' "XML patcher preserves stock display color tag"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_double_tap_to_wake">true</bool>' "XML patcher preserves stock double_tap tag"
assert_file_contains "$SB_STATE/work/device_features.xml" '<integer-array name="fpsList">' "XML patcher preserves stock fpsList array"
assert_file_not_contains "$SB_STATE/work/device_features.xml" 'support_smart_fps' "XML patcher does NOT inject FEAT_DISPLAY_HZ tags"
assert_file_contains "$SB_STATE/work/device_features.xml" '</features>' "XML patcher preserves closing </features> tag"
assert_file_contains "$SB_CHCON_LOG" "--reference=$SB_XML_DIR2/aurora.xml $SB_STATE/work/device_features.xml" "XML patcher restores SELinux context via chcon --reference before bind-mount"
assert_file_contains "$SB_MOUNT_LOG" "$SB_STATE/work/device_features.xml -> $SB_XML_DIR2/aurora.xml" "XML patcher calls mount --bind to original XML path"

# 6b: Never lower an already higher <integer> in stock XML + fallback + HOS 3 AOD safety gate
setup_sandbox "t6_xml_fallback"
write_mock_getprop "OS3.0" "" "36" "1" "unmatched_name"
write_mock_meminfo "7800000"
cat > "$SB_XML_DIR1/fallback_model.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<features>
    <integer name="device_level">5</integer>
    <integer name="freeform_max_count">8</integer>
    <bool name="support_aod">false</bool>
</features>
EOF
printf 'CS_TIER_MODE=balanced_pro\nFEAT_AOD_UNLOCK=1\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_contains "$SB_STATE/state.prop" "XML_SOURCE=$SB_XML_DIR1/fallback_model.xml" "XML patcher falls back to first valid .xml"
assert_file_contains "$SB_STATE/work/device_features.xml" '<integer name="device_level">5</integer>' "XML patcher never lowers existing higher integer device_level=5"
assert_file_contains "$SB_STATE/work/device_features.xml" '<integer name="freeform_max_count">8</integer>' "XML patcher never lowers existing higher integer freeform_max_count=8"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_aod">true</bool>' "XML patcher enables support_aod when FEAT_AOD_UNLOCK=1"
assert_file_not_contains "$SB_STATE/work/device_features.xml" 'support_aod_fullscreen' "HyperOS 3 safety gate skips support_aod_fullscreen"

# 6c: Fail-closed when XML is corrupt (missing </features>)
setup_sandbox "t6_xml_corrupt"
write_mock_getprop "OS2.0" "" "35" "1" "broken"
write_mock_meminfo "7800000"
printf '<features><bool name="support_aod">false</bool>\n' > "$SB_XML_DIR1/broken.xml"
run_post_fs_data
_rc=$?
assert_eq "$_rc" "0" "Corrupt XML fails closed without aborting boot"
assert_file_contains "$SB_STATE/state.prop" "XML_STATUS=skipped" "Corrupt XML sets XML_STATUS=skipped"
assert_eq "$(wc -l < "$SB_MOUNT_LOG" | tr -d ' ')" "0" "Corrupt XML never calls mount --bind"

# 6d: Fail-closed when mount --bind fails
setup_sandbox "t6_xml_mount_fail"
write_mock_getprop "OS2.0" "" "35" "1" "aurora"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR1/aurora.xml"
cat > "$SB_BIN/mount" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$SB_BIN/mount"
run_post_fs_data
_rc=$?
assert_eq "$_rc" "0" "Mount failure fails closed with exit 0"
assert_file_contains "$SB_STATE/state.prop" "XML_STATUS=skipped" "Mount failure records XML_STATUS=skipped"
assert_file_contains "$SB_STATE/state.prop" "XML_REASON=bind_mount_failed" "Mount failure records reason"

# ---------------------------------------------------------------------------
printf '=== Test 7: User-Space Capability Verifier (verified_active, ignored_by_rom, Binder error) ===\n'
setup_sandbox "t7_verifier"
write_mock_getprop "OS2.0" "" "35" "1" "aurora"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR1/aurora.xml"
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

run_post_fs_data
# Simulate ROM overriding one FEAT_DISPLAY_HZ prop while FEAT_BLUR & XML stay intact
tmp_db="$SB_PROPS_DB.mod"
awk -F '=' '$1 != "ro.miui.support_high_refresh_rate" { print $0 }' "$SB_PROPS_DB" > "$tmp_db"
printf 'ro.miui.support_high_refresh_rate=false\n' >> "$tmp_db"
mv -f "$tmp_db" "$SB_PROPS_DB"

run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_BLUR=verified_active" "Verifier marks matching FEAT_BLUR as verified_active"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_XML_PATCHER=verified_active" "Verifier confirms active XML bind-mount in /proc/mounts"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_COLOR_EXPERT=verified_active" "Verifier confirms Custom Color Expert verified_active in XML"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_DISPLAY_HZ=ignored_by_rom" "Verifier detects ROM-overridden FEAT_DISPLAY_HZ as ignored_by_rom"
assert_file_contains "$SB_STATE/overridden_props.list" "FEAT_DISPLAY_HZ|ro.miui.support_high_refresh_rate|true|false" "Verifier logs exact overridden prop diff"
assert_file_contains "$SB_SETTINGS_LOG" "--user 0 get global disable_window_blurs" "Verifier calls settings with --user 0"

# Simulate Android 16 Binder failure on settings get -> must NOT mark FEAT_MULTITASK as ignored_by_rom
cat > "$SB_BIN/settings" <<'EOF'
#!/bin/sh
printf 'cmd: Failure calling service settings: Failed transaction (2147483646)\n'
exit 0
EOF
chmod +x "$SB_BIN/settings"
run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_MULTITASK=verified_active" "Verifier ignores Binder Failure on settings and keeps matching props verified_active"
assert_file_not_contains "$SB_STATE/overridden_props.list" "Failed transaction" "Verifier does not record Binder failure as overridden prop"

# Simulate bind-mount stripped from /proc/mounts -> ignored_by_rom
: > "$SB_PROC_MOUNTS"
run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_XML_PATCHER=ignored_by_rom" "Verifier detects missing bind-mount in /proc/mounts as ignored_by_rom"

# ---------------------------------------------------------------------------
printf '=== Test 8: Transactional Settings Backup (--user 0), Rollback & Uninstall ===\n'
setup_sandbox "t8_settings_tx"
write_mock_getprop "OS3.0" "" "36" "1" "aurora"
write_mock_meminfo "7800000"
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

# Seed initial vendor settings: disable_window_blurs=1, stuck HOS3 background_blur_enable=1
printf 'global|disable_window_blurs=1\nsecure|background_blur_enable=1\n' > "$SB_SETTINGS_DB"

run_post_fs_data
run_service
assert_file_contains "$SB_SETTINGS_LOG" "--user 0 get global disable_window_blurs" "Settings TX reads via --user 0"
assert_file_contains "$SB_SETTINGS_LOG" "--user 0 put global disable_window_blurs 0" "Settings TX writes via --user 0"
assert_file_contains "$SB_SETTINGS_DB" "global|disable_window_blurs=0" "Settings TX applies disable_window_blurs=0 for FEAT_BLUR"
assert_file_contains "$SB_SETTINGS_DB" "secure|background_blur_enable=0" "One-time HOS3 cleanup clears stuck secure/background_blur_enable=1"
assert_file_contains "$SB_SETTINGS_DB" "global|coresurface_engine_v1=" "Settings TX syncs live Engine IPC global/coresurface_engine_v1"
assert_file_contains "$SB_SETTINGS_DB" "global|enable_freeform_support=1" "Settings TX applies enable_freeform_support=1 for FEAT_MULTITASK"
assert_file_contains "$SB_STATE/settings_backup.prop" "global|disable_window_blurs=1" "Settings TX backs up original value=1"
assert_file_contains "$SB_STATE/settings_backup.prop" "global|enable_freeform_support=null" "Settings TX backs up originally absent key as null"

# Re-run service.sh: backup MUST remain idempotent (still 1, not overwritten with 0!)
run_service
assert_file_contains "$SB_STATE/settings_backup.prop" "global|disable_window_blurs=1" "Idempotent backup never overwrites original value=1"

# Disable FEAT_MULTITASK and FEAT_BLUR -> automatic rollback on next sync
cat > "$SB_STATE/config.prop" <<'EOF'
FEAT_BLUR=0
FEAT_ANIMATIONS=auto
FEAT_XML_PATCHER=auto
FEAT_MULTITASK=0
FEAT_DISPLAY_HZ=auto
FEAT_GALLERY_PRO=0
FEAT_AOD_UNLOCK=0
EOF
run_service
assert_file_contains "$SB_SETTINGS_DB" "global|disable_window_blurs=1" "Disabling FEAT_BLUR restores original disable_window_blurs=1"
assert_file_not_contains "$SB_SETTINGS_DB" "global|enable_freeform_support=" "Disabling FEAT_MULTITASK deletes key whose original was null"
assert_file_contains "$SB_SETTINGS_LOG" "--user 0 delete global enable_freeform_support" "Settings TX deletes null-original key via --user 0"

# Verify uninstall.sh rolls back remaining keys (including Engine IPC) and cleans state dir
assert_file_contains "$SB_SETTINGS_DB" "system|miui_refresh_rate_adaptive=1" "FEAT_DISPLAY_HZ setting active before uninstall"
PATH="$SB_BIN:$PATH" CORESURFACE_MODDIR="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/uninstall.sh"
assert_file_not_contains "$SB_SETTINGS_DB" "system|miui_refresh_rate_adaptive=" "uninstall.sh rolls back remaining settings before deleting state"
assert_file_not_contains "$SB_SETTINGS_DB" "global|coresurface_engine_v1=" "uninstall.sh cleans up global/coresurface_engine_v1 IPC key"
assert_eq "$( [ -d "$SB_STATE" ] && printf 'exists' || printf 'removed' )" "removed" "uninstall.sh removes state directory"

# ---------------------------------------------------------------------------
printf '=== Test 9: WebUI Control Bridge (Granular Whitelist, Verify State & CoreFlow) ===\n'
setup_sandbox "t9_webui_ctl"
write_mock_getprop "OS2.0" "" "35" "1" "aurora"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR1/aurora.xml"
mkdir -p "$SB_CF_DIR"

cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "coreflowd" ] || [ "${1:-}" = "com.android.systemui" ]; then
  printf '9999\n'
  exit 0
fi
exit 1
EOF
chmod +x "$SB_BIN/pidof"

run_post_fs_data
run_service

_status_out=$(PATH="$SB_BIN:$PATH" \
  CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" \
  CORESURFACE_COREFLOW_DIR="$SB_CF_DIR" \
  sh "$SB_MOD/lib/webui_ctl.sh" status)
printf '%s\n' "$_status_out" > "$SB/status.out"

assert_file_contains "$SB/status.out" "coreflow_guard=active" "WebUI detects active CoreFlow Thermal Guard"
assert_file_contains "$SB/status.out" "verify_feat_blur=verified_active" "WebUI exposes verified_active status for FEAT_BLUR"
assert_file_contains "$SB/status.out" "xml_status=mounted" "WebUI exposes XML Patcher mounted status"
assert_file_contains "$SB/status.out" "xml_source=$SB_XML_DIR1/aurora.xml" "WebUI exposes discovered XML source path"

# Test tier & granular key whitelist (valid + invalid)
for _tm in auto low balanced_pro flagship; do
  PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" tier "$_tm" >/dev/null
  assert_file_contains "$SB_STATE/config.prop" "CS_TIER_MODE=${_tm}" "WebUI accepts tier=${_tm}"
done
if PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" tier invalid_tier >/dev/null 2>&1; then
  fail "WebUI should reject invalid tier mode"
else
  pass "WebUI rejects invalid tier mode"
fi

for _gk in FEAT_NATIVE_TIER FEAT_SURGICAL_GUARD FEAT_THERMAL_LOD FEAT_AOD_UNLOCK FEAT_BLUR FEAT_ANIMATIONS FEAT_XML_PATCHER FEAT_RRO_OVERLAYS FEAT_VIDEO_DEPTH FEAT_MULTITASK FEAT_DISPLAY_HZ FEAT_COLOR_EXPERT; do
  PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set "$_gk" 0 >/dev/null
  assert_file_contains "$SB_STATE/config.prop" "${_gk}=0" "WebUI accepts key ${_gk}=0"
done
for _mp in snappy fluid bouncy 0; do
  PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_MOTION_PROFILE "$_mp" >/dev/null
  assert_file_contains "$SB_STATE/config.prop" "FEAT_MOTION_PROFILE=${_mp}" "WebUI accepts FEAT_MOTION_PROFILE=${_mp}"
done
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_MOTION_PROFILE ios >/dev/null
assert_file_contains "$SB_STATE/config.prop" "FEAT_MOTION_PROFILE=bouncy" "Legacy alias ios maps cleanly to bouncy"
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_MOTION_PROFILE coloros >/dev/null
assert_file_contains "$SB_STATE/config.prop" "FEAT_MOTION_PROFILE=snappy" "Legacy alias coloros maps cleanly to snappy"
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_MOTION_PROFILE hyperos4 >/dev/null
assert_file_contains "$SB_STATE/config.prop" "FEAT_MOTION_PROFILE=fluid" "Legacy alias hyperos4 maps cleanly to fluid"
if PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_MOTION_PROFILE invalid >/dev/null 2>&1; then
  fail "WebUI should reject invalid FEAT_MOTION_PROFILE value"
else
  pass "WebUI rejects invalid FEAT_MOTION_PROFILE value"
fi
if PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_GALLERY_PRO 1 >/dev/null 2>&1; then
  fail "WebUI should reject removed FEAT_GALLERY_PRO key"
else
  pass "Zero-gimmick: WebUI rejects removed FEAT_GALLERY_PRO key"
fi
if PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set BAD_KEY 1 >/dev/null 2>&1; then
  fail "WebUI should reject unknown key"
else
  pass "WebUI rejects unknown config key"
fi

: > "$SB_MOD/disable"
printf '2\n' > "$SB_STATE/boot_strikes"
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" reset-safemode >/dev/null
assert_eq "$( [ -f "$SB_MOD/disable" ] && printf 'yes' || printf 'no' )" "no" "reset-safemode removes auto-resolved MODDIR/disable"
assert_eq "$(cat "$SB_STATE/boot_strikes")" "0" "reset-safemode resets boot_strikes=0"

# ---------------------------------------------------------------------------
printf '=== Test 10: Clean-Room RRO Staging, Fail-Closed Clear, Verifier & Zero-Gimmick HyperOS 3 Audit ===\n'
setup_sandbox "t10_rro_and_hos3"
write_mock_getprop "OS3.0" "" "36" "1" "aurora" "Redmi Note 15 Pro+ 5G"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR1/aurora.xml"

mkdir -p "$SB_MOD/overlays"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceSystemUI.apk"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceSystemUILiteBlur.apk"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceThemeManager.apk"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceMiWallpaper.apk"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceMiuiAod.apk"

cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

cat > "$SB_BIN/cmd" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "overlay" ] && [ "${2:-}" = "list" ]; then
  printf 'com.android.systemui\n[x] org.mystivara.coresurface.overlay.systemui\n'
  printf 'com.android.thememanager\n[x] org.mystivara.coresurface.overlay.thememanager\n'
  printf 'com.miui.miwallpaper\n[x] org.mystivara.coresurface.overlay.miwallpaper\n'
  printf 'com.miui.aod\n[x] org.mystivara.coresurface.overlay.miuiaod\n'
  exit 0
fi
exit 1
EOF
chmod +x "$SB_BIN/cmd"

run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.advanced_visual_release=3" "HyperOS 3 skips dropped legacy persist.sys.advanced_visual_release"
assert_file_contains "$SB_PROPS_LOG" "PURGED:persist.sys.advanced_visual_release" "Cleanup v3 purges leaked persist.sys.advanced_visual_release from /data/property"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.background_blur_status_default=" "HyperOS 3 Flagship does not fight user's Advanced Textures Settings toggle"
assert_file_contains "$SB_PROPS_LOG" "debug.sysui.use_control_center=1" "Verified split Control Center prop is applied"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.background_blur_version=2" "HyperOS 3 avoids forcing blur version 2"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.feature.island=1" "Zero-gimmick: purged placebo persist.sys.feature.island prop"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.hyperai_enabled=true" "Zero-gimmick: purged placebo persist.sys.hyperai_enabled prop"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.aod_limit_disabled=true" "Zero-gimmick: purged placebo persist.sys.aod_limit_disabled prop"
assert_file_contains "$SB_PROPS_LOG" "PURGED:persist.sys.support_window_mishadow" "One-time cleanup purges leaked persist.* keys from /data/property"
assert_eq "$( [ -f "$SB_MOD/system.prop" ] && printf 'exists' || printf 'absent' )" "absent" "Never creates system.prop (strictly memory-only resetprop -n)"
assert_file_contains "$SB_CHCON_LOG" "-R u:object_r:system_file:s0 $SB_MOD/system" "RRO Manager restores SELinux system_file context on staged overlays"
assert_eq "$( [ -f "$SB_MOD/system/product/media/wallpaper/sysui_editor_wallpaper_group/enable_video_depth" ] && printf 'yes' || printf 'no' )" "yes" "Stages zero-byte Lockscreen Video Depth marker in Balance Pro/Pro+"
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceSystemUI.apk" ] && printf 'yes' || printf 'no' )" "yes" "RRO stages CoreSurfaceSystemUI.apk"
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceSystemUILiteBlur.apk" ] && printf 'yes' || printf 'no' )" "no" "RRO skips LiteBlur overlay when full FEAT_BLUR is active"
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceMiuiAod.apk" ] && printf 'yes' || printf 'no' )" "yes" "RRO stages CoreSurfaceMiuiAod.apk by default for Non-LTPO AOD"

CORESURFACE_LIVE_OVERLAY_DIR="$SB_MOD/system/product/overlay" \
CORESURFACE_VIDEO_DEPTH_PATH="$SB_MOD/system/product/media/wallpaper/sysui_editor_wallpaper_group/enable_video_depth" run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_BLUR=verified_active" "HyperOS 3 FEAT_BLUR achieves 100% verified_active"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_VIDEO_DEPTH=verified_active" "Verifier marks FEAT_VIDEO_DEPTH as verified_active"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_RRO_OVERLAYS=verified_active" "Verifier marks active RRO overlays via cmd overlay list as verified_active"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_RRO_ACTIVE=4" "Verifier counts 4/4 active RRO overlays"
assert_file_contains "$SB_STATE/verify.state" "COMPAT_SCORE_PCT=100" "ROM Compatibility Score reaches 100% when all active features match"

# Low tier keeps SystemUI + ThemeManager RRO but skips heavy MiWallpaper & Video Depth
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" tier low >/dev/null
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceSystemUI.apk" ] && printf 'yes' || printf 'no' )" "yes" "Low tier keeps CoreSurfaceSystemUI.apk"
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceMiWallpaper.apk" ] && printf 'yes' || printf 'no' )" "no" "Low tier skips heavy CoreSurfaceMiWallpaper.apk"
assert_eq "$( [ -e "$SB_MOD/system/product/media/wallpaper/sysui_editor_wallpaper_group/enable_video_depth" ] && printf 'yes' || printf 'no' )" "no" "Low tier skips Video Depth marker"

# Turning FEAT_AOD_UNLOCK=0 removes CoreSurfaceMiuiAod.apk
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_AOD_UNLOCK 0 >/dev/null
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceMiuiAod.apk" ] && printf 'yes' || printf 'no' )" "no" "Disabling FEAT_AOD_UNLOCK=0 removes CoreSurfaceMiuiAod.apk"

# Turning FEAT_RRO_OVERLAYS=0 via webui_ctl immediately unstages RRO APKs for next boot
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_RRO_OVERLAYS 0 >/dev/null
assert_eq "$( [ -d "$SB_MOD/system/product/overlay" ] && printf 'exists' || printf 'cleared' )" "cleared" "Setting FEAT_RRO_OVERLAYS=0 clears staged overlays for next boot"

# Watchdog Safe-Mode (boot_strikes=2) clears system.prop, staged RRO APKs & Video Depth marker fail-closed
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" tier flagship >/dev/null
printf '2\n' > "$SB_STATE/boot_strikes"
run_post_fs_data
assert_eq "$( [ -f "$SB_MOD/system.prop" ] && printf 'exists' || printf 'cleared' )" "cleared" "Watchdog Safe-Mode clears system.prop fail-closed"
assert_eq "$( [ -d "$SB_MOD/system/product/overlay" ] && printf 'exists' || printf 'cleared' )" "cleared" "Watchdog Safe-Mode clears staged RRO overlays fail-closed"
assert_eq "$( [ -e "$SB_MOD/system/product/media/wallpaper/sysui_editor_wallpaper_group/enable_video_depth" ] && printf 'exists' || printf 'cleared' )" "cleared" "Watchdog Safe-Mode clears Video Depth marker fail-closed"

# ---------------------------------------------------------------------------
printf '=== Test 11: 4-Tier Switching, Instant Hot-Sync & Diagnostic Report ===\n'
setup_sandbox "t11_tiers_hotsync"
write_mock_getprop "OS3.0" "" "36" "1" "aurora" "Redmi Note 15 5G"
write_mock_meminfo "7800000"
mkdir -p "$SB_MOD/overlays"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceSystemUI.apk"
printf 'global|disable_window_blurs=1\n' > "$SB_SETTINGS_DB"

PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" \
  sh "$SB_MOD/lib/webui_ctl.sh" tier flagship >/dev/null
assert_file_contains "$SB_STATE/config.prop" "CS_TIER_MODE=flagship" "tier flagship sets CS_TIER_MODE=flagship"
assert_file_contains "$SB_STATE/config.prop" "FEAT_MOTION_PROFILE=snappy" "tier flagship sets canonical FEAT_MOTION_PROFILE=snappy"
assert_file_contains "$SB_SETTINGS_DB" "global|disable_window_blurs=0" "tier flagship immediately hot-syncs settings"
assert_file_contains "$SB_SETTINGS_DB" "secure|aod_mode_time=0" "Non-LTPO AOD sets secure/aod_mode_time=0"
assert_file_contains "$SB_SETTINGS_DB" "global|coresurface_engine_v1=motion=snappy;native=1;guard=1;thermallod=1;aod=1" "tier flagship pushes live Motion Engine IPC immediately"

PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" \
  sh "$SB_MOD/lib/webui_ctl.sh" tier low >/dev/null
assert_file_contains "$SB_STATE/config.prop" "CS_TIER_MODE=low" "tier low sets CS_TIER_MODE=low"
assert_file_contains "$SB_STATE/config.prop" "FEAT_MOTION_PROFILE=fluid" "tier low sets smooth FEAT_MOTION_PROFILE=fluid"
assert_file_contains "$SB_SETTINGS_DB" "global|disable_window_blurs=0" "tier low STILL keeps standard blur enabled"

PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" \
  sh "$SB_MOD/lib/webui_ctl.sh" hot-sync >/dev/null
assert_file_contains "$SB_SETTINGS_DB" "global|disable_window_blurs=0" "hot-sync applies settings without reboot"

_diag=$(PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" \
  sh "$SB_MOD/lib/webui_ctl.sh" diag-report)
printf '%s\n' "$_diag" > "$SB/diag.txt"
assert_file_contains "$SB/diag.txt" "=== CoreSurface v1.3.0 Flagship Motion Diagnostic Report ===" "diag-report outputs structured Flagship Motion v1.3.0 header"
assert_file_contains "$SB/diag.txt" "Motion Engine:" "diag-report includes Motion Engine telemetry line"
assert_file_contains "$SB/diag.txt" "Custom Color Expert:" "diag-report includes Custom Color Expert status"
assert_file_contains "$SB/diag.txt" "AOD Unlock:" "diag-report includes AOD Unlock status"

if PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" preset invalid-mode >/dev/null 2>&1; then
  fail "WebUI should reject unknown preset name"
else
  pass "WebUI rejects unknown preset name"
fi

# ---------------------------------------------------------------------------
printf '=== Test 12: Custom Color Expert Always-On (All Modes) & Non-LTPO AOD XML ===\n'
setup_sandbox "t12_color_expert_and_aod"
write_mock_getprop "OS3.0" "" "36" "1" "aurora" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
cat > "$SB_XML_DIR1/aurora.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<features>
    <bool name="support_display_expert_mode">false</bool>
    <bool name="support_screen_effect">true</bool>
    <bool name="support_double_tap_to_wake">true</bool>
    <bool name="support_aod">false</bool>
</features>
EOF
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

# Even in Low mode (Redmi Note 15 5G), Custom Color Expert & Non-LTPO AOD XML tags are enabled,
# while support_advanced_textures is NOT injected!
run_post_fs_data
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_display_expert_mode">true</bool>' "Low mode upgrades support_display_expert_mode -> true"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_screen_effect">true</bool>' "Preserves stock Vivid/Saturated/Standard tag"
assert_file_not_contains "$SB_STATE/work/device_features.xml" 'support_advanced_textures' "Low mode never adds support_advanced_textures"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="aod_support_keycode_goto_dismiss">true</bool>' "Non-LTPO AOD adds aod_support_keycode_goto_dismiss=true"
assert_file_not_contains "$SB_STATE/work/device_features.xml" 'support_aod_fullscreen' "HyperOS 3 still skips support_aod_fullscreen"

run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_COLOR_EXPERT=verified_active" "Verifier confirms FEAT_COLOR_EXPERT as verified_active in Low mode"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_AOD_UNLOCK=verified_active" "Verifier confirms FEAT_AOD_UNLOCK as verified_active via XML"

# ---------------------------------------------------------------------------
printf '=== Test 13: 60/120 Hz Motion Engine, Recents/AOD Telemetry & Zero-Reboot IPC ===\n'
setup_sandbox "t13_hybrid_engine"
write_mock_getprop "OS3.0" "" "36" "1" "aurora"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR1/aurora.xml"
printf 'CS_TIER_MODE=auto\nFEAT_MOTION_PROFILE=hyperos4\n' > "$SB_STATE/config.prop"
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

run_post_fs_data

# 13a: Engine APK installed, but NOT enabled in LSPosed yet -> honest pending_lsposed (ZERO gimmick!)
CORESURFACE_ENGINE_INSTALLED=1 \
CORESURFACE_ENGINE_SYSUI_TELEM="$SB/missing_sysui.prop" \
CORESURFACE_ENGINE_HOME_TELEM="$SB/missing_home.prop" \
CORESURFACE_ENGINE_AOD_TELEM="$SB/missing_aod.prop" \
  run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_INSTALLED=1" "Verifier detects installed CoreSurfaceEngine.apk"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_ACTIVE=0" "Verifier honestly reports ENGINE_ACTIVE=0 before LSPosed hook runs"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_MOTION_PROFILE=pending_lsposed" "Zero-gimmick: marks FEAT_MOTION_PROFILE as pending_lsposed when unhooked"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_NATIVE_TIER=pending_lsposed" "Zero-gimmick: marks FEAT_NATIVE_TIER as pending_lsposed when unhooked"

# 13b: Live telemetry from SystemUI + MiuiHome + MiuiAod (with DISPLAY_HZ & AOD_GATES)
cat > "$SB/sysui_telem.prop" <<'EOF'
ENGINE_ACTIVE=1
ENGINE_MODE=NATIVE_MOTION
MOTION_PROFILE=hyperos4
DISPLAY_HZ=120
LOD_TIER=FULL
HOOKS_BOUND=ToastGuard,NativeFlagshipTier,FolmePhysics
NATIVE_GATES=14
FOLME_HOOKS=6
AOD_GATES=0
SPRINGS_TUNED=48
TOASTS_GUARDED=3
RECENTS_GUARDED=0
EOF
cat > "$SB/home_telem.prop" <<'EOF'
ENGINE_ACTIVE=1
ENGINE_MODE=NATIVE_MOTION
MOTION_PROFILE=hyperos4
DISPLAY_HZ=120
LOD_TIER=FULL
HOOKS_BOUND=ToastGuard,NativeFlagshipTier,FolmePhysics,RecentsGuard
NATIVE_GATES=11
FOLME_HOOKS=4
AOD_GATES=0
SPRINGS_TUNED=72
TOASTS_GUARDED=0
RECENTS_GUARDED=4
EOF
cat > "$SB/aod_telem.prop" <<'EOF'
ENGINE_ACTIVE=1
ENGINE_MODE=NATIVE_MOTION
MOTION_PROFILE=hyperos4
DISPLAY_HZ=60
LOD_TIER=FULL
HOOKS_BOUND=AodNonLtpoUnlock,AodFlagshipTier
NATIVE_GATES=2
FOLME_HOOKS=2
AOD_GATES=4
SPRINGS_TUNED=5
TOASTS_GUARDED=0
RECENTS_GUARDED=0
EOF

CORESURFACE_ENGINE_INSTALLED=1 \
CORESURFACE_ENGINE_SYSUI_TELEM="$SB/sysui_telem.prop" \
CORESURFACE_ENGINE_HOME_TELEM="$SB/home_telem.prop" \
CORESURFACE_ENGINE_AOD_TELEM="$SB/aod_telem.prop" \
  run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_ACTIVE=1" "Verifier confirms active Engine runtime from telemetry"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_MODE=NATIVE_MOTION" "Verifier records honest NATIVE_MOTION engine mode"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_MOTION=fluid" "Verifier records live MOTION_PROFILE=fluid (legacy hyperos4 mapped cleanly)"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_HZ=120" "Verifier records highest live DISPLAY_HZ=120"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_LOD=FULL" "Verifier reports live Thermal-Adaptive LOD tier"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_HOOKS=ToastGuard,NativeFlagshipTier,FolmePhysics,RecentsGuard,AodNonLtpoUnlock,AodFlagshipTier" "Verifier deduplicates hook names across SystemUI + MiuiHome + MiuiAod"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_NATIVE_GATES=27" "Verifier aggregates native HyperOS flagship gates"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_FOLME_HOOKS=12" "Verifier aggregates hooked Folme/SpringForce methods"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_AOD_GATES=4" "Verifier aggregates Non-LTPO AOD gates"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_SPRINGS=125" "Verifier aggregates tuned spring animations"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_TOASTS=3" "Verifier reports guarded Toast count"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_RECENTS=4" "Verifier reports guarded Recents count"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_MOTION_PROFILE=verified_active" "Motion Profile verified_active only with bound FolmePhysics hook"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_NATIVE_TIER=verified_active" "Native Tier verified_active only with bound NativeFlagshipTier hook"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_SURGICAL_GUARD=verified_active" "Surgical Guard verified_active only with bound Toast/Recents hooks"

# 13c: Live Motion Profile switch via webui_ctl pushes zero-Binder debug.coresurface.cfg IMMEDIATELY with ZERO pending reboot!
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" \
  CORESURFACE_ENGINE_INSTALLED=1 CORESURFACE_ENGINE_SYSUI_TELEM="$SB/sysui_telem.prop" \
  CORESURFACE_ENGINE_HOME_TELEM="$SB/home_telem.prop" CORESURFACE_ENGINE_AOD_TELEM="$SB/aod_telem.prop" \
  sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_MOTION_PROFILE silk >/dev/null
assert_file_contains "$SB_PROPS_DB" "debug.coresurface.cfg=motion=snappy;native=1;guard=1;thermallod=1;aod=1" "Live switch updates zero-Binder debug.coresurface.cfg via resetprop -n instantly (legacy silk -> snappy)"
assert_file_not_contains "$SB_STATE/state.prop" "FEAT_MOTION_PROFILE" "Live Motion Profile switch does NOT add to PENDING_KEYS (zero reboot required)"

# 13d: SELinux-safe pm install -r -S <size> streaming in service.sh (idempotent)
SB_PM_LOG="$SB/pm.calls"
: > "$SB_PM_LOG"
printf 'FAKE_ENGINE_APK_BYTES_1234567890' > "$SB_STATE/CoreSurfaceEngine.apk"
cat > "$SB_BIN/pm" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SB_PM_LOG"
case "\$1" in
  path)
    if [ -f "$SB_STATE/.engine_installed.sig" ]; then
      printf 'package:/data/app/org.mystivara.coresurface.engine/base.apk\n'
      exit 0
    fi
    exit 1
    ;;
  install)
    cat >/dev/null
    printf 'Success\n'
    exit 0
    ;;
esac
exit 1
EOF
chmod +x "$SB_BIN/pm"
run_service
assert_file_contains "$SB_PM_LOG" "install -r -d -S 32" "service.sh installs CoreSurfaceEngine.apk via SELinux-safe stdin stream (pm install -r -d -S)"
assert_eq "$( [ -f "$SB_STATE/.engine_installed.sig" ] && printf 'yes' || printf 'no' )" "yes" "service.sh records idempotent .engine_installed.sig stamp"
: > "$SB_PM_LOG"
run_service
assert_file_not_contains "$SB_PM_LOG" "install -r" "service.sh skips redundant pm install when APK signature unchanged"

# Same-signature update: upgrades in-place via pm install -r -d with ZERO pm uninstall (preserves LSPosed enabled state & scopes)
printf 'INPLACE_SAME_CERT_UPDATED_APK_123456' > "$SB_STATE/CoreSurfaceEngine.apk"
: > "$SB_PM_LOG"
run_service
assert_file_contains "$SB_PM_LOG" "install -r -d -S 36" "Same-signature update upgrades in-place via pm install -r -d -S"
assert_file_not_contains "$SB_PM_LOG" "uninstall" "Same-signature update NEVER calls pm uninstall (LSPosed state preserved)"
assert_file_contains "$SB_STATE/coresurface.log" "upgraded CoreSurfaceEngine.apk in-place" "Log confirms in-place LSPosed-preserving upgrade"

# 13e: Signature-mismatch upgrade (INSTALL_FAILED_UPDATE_INCOMPATIBLE) automatically uninstalls old cert & retries
printf 'UPDATED_ENGINE_APK_BYTES_WITH_NEW_CERT_123456' > "$SB_STATE/CoreSurfaceEngine.apk"
SB_PM_MARKER="$SB/pm.uninstalled"
: > "$SB_PM_LOG"
cat > "$SB_BIN/pm" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SB_PM_LOG"
case "\$1" in
  path)
    printf 'package:/data/app/org.mystivara.coresurface.engine/base.apk\n'
    exit 0
    ;;
  uninstall)
    : > "$SB_PM_MARKER"
    printf 'Success\n'
    exit 0
    ;;
  install)
    cat >/dev/null
    if [ ! -f "$SB_PM_MARKER" ]; then
      printf 'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package org.mystivara.coresurface.engine signatures do not match newer version]\n'
      exit 1
    fi
    printf 'Success\n'
    exit 0
    ;;
esac
exit 1
EOF
chmod +x "$SB_BIN/pm"
run_service
assert_file_contains "$SB_PM_LOG" "uninstall org.mystivara.coresurface.engine" "service.sh automatically uninstalls mismatched-signature old APK before retrying"
assert_eq "$( [ -f "$SB_PM_MARKER" ] && printf 'yes' || printf 'no' )" "yes" "Signature-mismatch recovery completed cleanly"

# ---------------------------------------------------------------------------
printf '=== Test 14: Interactive Volume Up / Volume Down 4-Tier Installer (customize.sh) ===\n'
setup_sandbox "t14_volkey_installer"
cp "$REPO_ROOT/customize.sh" "$SB_MOD/"
mkdir -p "$SB_MOD/overlays"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceSystemUI.apk"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceThemeManager.apk"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceMiWallpaper.apk"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceMiuiAod.apk"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "7500000"

# Mock getevent sequence: Vol+ (1->2), Vol+ (2->3 balanced_pro), Vol- (confirm tier), Vol+ (1->2 silk), Vol- (confirm motion)
SB_VK_STEP="$SB/vk.step"
printf '0\n' > "$SB_VK_STEP"
cat > "$SB_BIN/getevent" <<EOF
#!/bin/sh
n=\$(cat "$SB_VK_STEP")
n=\$((n + 1))
printf '%s\n' "\$n" > "$SB_VK_STEP"
case "\$n" in
  1|2|4) printf '/dev/input/event1: EV_KEY KEY_VOLUMEUP DOWN\n' ;;
  3|5)   printf '/dev/input/event1: EV_KEY KEY_VOLUMEDOWN DOWN\n' ;;
esac
exit 0
EOF
chmod +x "$SB_BIN/getevent"

PATH="$SB_BIN:$PATH" MODPATH="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" \
  sh "$SB_MOD/customize.sh" >/dev/null
assert_file_contains "$SB_STATE/config.prop" "CS_TIER_MODE=balanced_pro" "Volume Up x2 + Volume Down selects balanced_pro tier"
assert_file_contains "$SB_STATE/config.prop" "FEAT_MOTION_PROFILE=snappy" "Volume Up + Volume Down selects Snappy (snappy) profile"
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceMiWallpaper.apk" ] && printf 'yes' || printf 'no' )" "yes" "customize.sh stages balanced_pro RRO overlays immediately after volume selection"

# Non-interactive fallback leaves CS_TIER_MODE=auto cleanly without hanging
setup_sandbox "t14_noninteractive"
cp "$REPO_ROOT/customize.sh" "$SB_MOD/"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
PATH="$SB_BIN:$PATH" MODPATH="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" \
  CORESURFACE_NONINTERACTIVE=1 sh "$SB_MOD/customize.sh" >/dev/null
assert_file_contains "$SB_STATE/config.prop" "CS_TIER_MODE=auto" "Non-interactive install preserves default CS_TIER_MODE=auto cleanly"

# ---------------------------------------------------------------------------
printf '=== Test 15: Device Logic & OS/System Bug Detector + Universal UI Curve Telemetry ===\n'
setup_sandbox "t15_os_bug_logic"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
write_sample_xml "$SB_XML_DIR1/kunzite.xml"
mkdir -p "$SB_MOD/overlays"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceSystemUI.apk"
# Seed pre-existing stale XML mount + leaked persist prop + vendor blur throttle
printf '/dev/block/dm-0 /product/etc/device_features/kunzite.xml ext4 ro 0 0\n' > "$SB_PROC_MOUNTS"
printf 'persist.sys.advanced_visual_release=3\nro.sf.blurs_are_expensive=1\n' > "$SB_PROPS_DB"
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

run_post_fs_data
assert_file_contains "$SB_STATE/os_bugs.state" "HOS3_ADVTEX_TOAST_RECENTS" "Device Logic detects HyperOS 3 Advanced Textures Toast/Recents bug"
assert_file_contains "$SB_STATE/os_bugs.state" "HOS3_AOD_FULLSCREEN_CRASH" "Device Logic detects HyperOS 3 fullscreen AOD crash risk"
assert_file_contains "$SB_STATE/os_bugs.state" "SDK35_ROOT_BINDER_GUARD" "Device Logic detects Android 16 root Binder restriction"
assert_file_contains "$SB_STATE/os_bugs.state" "SOFT_REBOOT_STALE_XML" "Device Logic detects stale soft-reboot XML mount"
assert_file_contains "$SB_STATE/os_bugs.state" "NON_LTPO_AOD_10S_CAP" "Device Logic detects Non-LTPO 10s AOD cap"
assert_file_contains "$SB_STATE/os_bugs.state" "VENDOR_BLUR_LOWRAM_THROTTLE" "Device Logic detects vendor blurs_are_expensive throttle"
assert_file_contains "$SB_STATE/os_bugs.state" "LEAKED_PERSIST_PROPS" "Device Logic detects leaked persist.sys.advanced_visual_release"

# Post-boot late scan detects missing meta-overlayfs when staged APK is absent from live overlay dir,
# and aggregates universal UI Curves telemetry from com.android.settings
cat > "$SB/settings_telem.prop" <<'EOF'
ENGINE_ACTIVE=1
ENGINE_MODE=NATIVE_MOTION
MOTION_PROFILE=silk
DISPLAY_HZ=120
LOD_TIER=FULL
HOOKS_BOUND=FolmePhysics,UiCurvePhysics
NATIVE_GATES=0
FOLME_HOOKS=3
AOD_GATES=0
SPRINGS_TUNED=10
CURVES_APPLIED=64
TOASTS_GUARDED=0
RECENTS_GUARDED=0
CIRCUIT_TRIPS=0
EOF

CORESURFACE_LIVE_OVERLAY_DIR="$SB/empty_live_overlay" \
CORESURFACE_ENGINE_INSTALLED=1 \
CORESURFACE_ENGINE_SYSUI_TELEM="$SB/missing_sysui.prop" \
CORESURFACE_ENGINE_HOME_TELEM="$SB/missing_home.prop" \
CORESURFACE_ENGINE_AOD_TELEM="$SB/missing_aod.prop" \
CORESURFACE_ENGINE_SETTINGS_TELEM="$SB/settings_telem.prop" \
  run_service
assert_file_contains "$SB_STATE/os_bugs.state" "MISSING_META_OVERLAYFS" "Late Device Logic detects missing meta-overlayfs metamodule"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_CURVES=64" "Verifier aggregates universal UI SpringPhysicsCurve count from Settings"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_HOOKS=FolmePhysics,UiCurvePhysics" "Verifier records UiCurvePhysics universal ValueAnimator hook"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_CIRCUITS=0" "DeviceBugGuard reports 0 circuit breaker trips"

# ---------------------------------------------------------------------------
printf '=== Test 16: Immutable Stock Snapshot (No Flagship Self-Misclassification) & Never-Downgrade ===\n'
setup_sandbox "t16_stock_snapshot"
write_mock_getprop "OS3.0" "" "36" "1" "nonflag" "POCO F7 Ultra"
write_mock_meminfo "11800000"
write_sample_xml "$SB_XML_DIR1/nonflag.xml"
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

run_post_fs_data
assert_file_contains "$SB_STATE/stock_caps.prop" "STOCK_DEVICE_LEVEL=1" "Early boot snapshots true factory STOCK_DEVICE_LEVEL=1"
assert_file_contains "$SB_STATE/stock_caps.prop" "STOCK_HAS_BLUR=0" "Early boot snapshots true factory STOCK_HAS_BLUR=0"
assert_file_contains "$SB_STATE/state.prop" "EFF_TIER=flagship" "12GB non-native device resolves flagship tier at post-fs-data"

# Simulate bind-mount now exposing CoreSurface's patched XML (device_level=3 + blur=true) at original XML path
cp "$SB_STATE/work/device_features.xml" "$SB_XML_DIR1/nonflag.xml"

# Late boot service.sh and WebUI MUST reuse stock_caps.prop and NOT misclassify as motion_only!
run_service
assert_file_contains "$SB_SETTINGS_DB" "global|disable_window_blurs=0" "service.sh keeps flagship blur setting (never misclassified as motion_only)"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_BLUR=verified_active" "service.sh verifies FEAT_BLUR active instead of skipping"

_st16=$(PATH="$SB_BIN:$PATH" CORESURFACE_MODDIR="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" CORESURFACE_XML_SEARCH_DIRS="$SB_XML_DIR1:$SB_XML_DIR2" \
  sh "$SB_MOD/lib/webui_ctl.sh" status)
printf '%s\n' "$_st16" > "$SB/status16.out"
assert_file_contains "$SB/status16.out" "detected_tier=flagship" "WebUI preserves true detected_tier=flagship after XML bind-mount"
assert_file_contains "$SB/status16.out" "eff_tier=flagship" "WebUI preserves true eff_tier=flagship after XML bind-mount"

# Never-Downgrade on persist.sys.deviceLevelList when user selects low tier on stock c:3,g:3
setup_sandbox "t16_nd_levellist"
write_mock_getprop "OS3.0" "" "36" "1" "middev" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
printf 'persist.sys.deviceLevelList=v:1,c:3,g:3\n' > "$SB_PROPS_DB"
printf 'CS_TIER_MODE=low\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_contains "$SB_PROPS_LOG" "persist.sys.deviceLevelList=v:1,c:3,g:3" "Never-Downgrade preserves stock c:3,g:3 even in low tier"

# ---------------------------------------------------------------------------
printf '=== Test 17: Android 16 su 2000 Semicolon-Safe IPC & Stale-Boot BOOT_ID Guard ===\n'
setup_sandbox "t17_binder_and_bootid"
write_mock_getprop "OS3.0" "" "36" "1" "aurora" "Redmi Note 15 Pro+ 5G"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR1/aurora.xml"
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

# Mock settings that rejects direct UID 0 calls (Android 16 Binder) and only succeeds under SU2000_ACTIVE=1
cat > "$SB_BIN/settings" <<EOF
#!/bin/sh
if [ "\${SU2000_ACTIVE:-0}" != "1" ]; then
  printf 'Failure calling service settings: Failed transaction (2147483646)\n' >&2
  exit 1
fi
printf '%s\n' "\$*" >> "$SB_SETTINGS_LOG"
if [ "\${1:-}" = "--user" ]; then
  shift 2
fi
cmd=\${1:-}
ns=\${2:-}
key=\${3:-}
val=\${4:-}
id="\${ns}|\${key}"
case "\$cmd" in
  get)
    out=\$(awk -F '=' -v id="\$id" '\$1 == id { sub(/^[^=]*=/, ""); print; exit }' "$SB_SETTINGS_DB" 2>/dev/null || true)
    if [ -z "\$out" ]; then printf 'null\n'; else printf '%s\n' "\$out"; fi
    ;;
  put)
    tmp="$SB_SETTINGS_DB.tmp.\$\$"
    awk -F '=' -v id="\$id" '\$1 != id { print \$0 }' "$SB_SETTINGS_DB" > "\$tmp" 2>/dev/null || : > "\$tmp"
    printf '%s=%s\n' "\$id" "\$val" >> "\$tmp"
    mv -f "\$tmp" "$SB_SETTINGS_DB"
    ;;
  delete)
    tmp="$SB_SETTINGS_DB.tmp.\$\$"
    awk -F '=' -v id="\$id" '\$1 != id { print \$0 }' "$SB_SETTINGS_DB" > "\$tmp" 2>/dev/null || : > "\$tmp"
    mv -f "\$tmp" "$SB_SETTINGS_DB"
    ;;
esac
exit 0
EOF
chmod +x "$SB_BIN/settings"

cat > "$SB_BIN/su" <<'EOF'
#!/bin/sh
# Simulate `su 2000 -c "<cmd>"` executing via real /bin/sh so unquoted semicolons would split!
if [ "$1" = "2000" ] && [ "$2" = "-c" ]; then
  SU2000_ACTIVE=1 sh -c "$3"
  exit $?
fi
exit 1
EOF
chmod +x "$SB_BIN/su"

printf 'CS_TIER_MODE=auto\nFEAT_MOTION_PROFILE=hyperos4\n' > "$SB_STATE/config.prop"
run_post_fs_data

# Stale-boot telemetry with an OLD boot_id MUST be rejected by verifier.sh
printf 'boot-uuid-current-2222\n' > "$SB/boot_id"
cat > "$SB/stale_sysui.prop" <<'EOF'
ENGINE_ACTIVE=1
BOOT_ID=boot-uuid-previous-1111
ENGINE_MODE=NATIVE_MOTION
MOTION_PROFILE=silk
DISPLAY_HZ=120
LOD_TIER=FULL
HOOKS_BOUND=FolmePhysics,NativeFlagshipTier
EOF

CORESURFACE_BOOT_ID_FILE="$SB/boot_id" \
CORESURFACE_ENGINE_INSTALLED=1 \
CORESURFACE_ENGINE_SYSUI_TELEM="$SB/stale_sysui.prop" \
CORESURFACE_ENGINE_HOME_TELEM="$SB/missing_home.prop" \
CORESURFACE_ENGINE_AOD_TELEM="$SB/missing_aod.prop" \
CORESURFACE_ENGINE_SETTINGS_TELEM="$SB/missing_settings.prop" \
  run_service

assert_file_contains "$SB_SETTINGS_DB" "global|coresurface_engine_v1=motion=fluid;native=1;guard=1;thermallod=1;aod=1" "su 2000 -c preserves full semicolon-delimited coresurface_engine_v1 without shell splitting"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_ACTIVE=0" "Verifier rejects stale telemetry from previous BOOT_ID"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_MOTION_PROFILE=pending_lsposed" "Stale telemetry does not fake verified_active"

# Matching current BOOT_ID is accepted
cat > "$SB/fresh_sysui.prop" <<'EOF'
ENGINE_ACTIVE=1
BOOT_ID=boot-uuid-current-2222
ENGINE_MODE=NATIVE_MOTION
MOTION_PROFILE=hyperos4
DISPLAY_HZ=120
LOD_TIER=FULL
HOOKS_BOUND=FolmePhysics,NativeFlagshipTier,ToastGuard
BUGS_MITIGATED=HOS3_MiBlurRuntime
EOF

CORESURFACE_BOOT_ID_FILE="$SB/boot_id" \
CORESURFACE_ENGINE_INSTALLED=1 \
CORESURFACE_ENGINE_SYSUI_TELEM="$SB/fresh_sysui.prop" \
CORESURFACE_ENGINE_HOME_TELEM="$SB/missing_home.prop" \
CORESURFACE_ENGINE_AOD_TELEM="$SB/missing_aod.prop" \
CORESURFACE_ENGINE_SETTINGS_TELEM="$SB/missing_settings.prop" \
  run_service

assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_ACTIVE=1" "Verifier accepts live telemetry matching current BOOT_ID"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_BUGS=HOS3_MiBlurRuntime" "Verifier surfaces runtime BUGS_MITIGATED telemetry"

# ---------------------------------------------------------------------------
printf '=== Test 18: Safe-Mode Engine Kill-Switch, action.sh & Clean Uninstall ===\n'
setup_sandbox "t18_safemode_action_uninstall"
write_mock_getprop "OS3.0" "" "36" "1" "aurora" "Redmi Note 15 Pro+ 5G"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR1/aurora.xml"

# Trigger Safe-Mode (strike 2): post-fs-data applies 0 props, then service.sh disarms lingering Engine IPC
printf 'debug.coresurface.cfg=motion=silk;native=1;guard=1;thermallod=1;aod=1\n' > "$SB_PROPS_DB"
printf '2\n' > "$SB_STATE/boot_strikes"
run_post_fs_data
assert_eq "$(wc -l < "$SB_PROPS_LOG" | tr -d ' ')" "0" "Safe-Mode post-fs-data executes strictly 0 resetprop calls"
run_service
assert_file_contains "$SB_PROPS_DB" "debug.coresurface.cfg=motion=off;native=0;guard=0;thermallod=0;aod=0" "Safe-Mode service.sh disarms lingering Layer 2 Engine IPC"

# Test action.sh runs cleanly and produces diagnostic report
_act_out=$(PATH="$SB_BIN:$PATH" CORESURFACE_MODDIR="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/action.sh")
printf '%s\n' "$_act_out" > "$SB/action.out"
assert_file_contains "$SB/action.out" "CoreSurface v1.3.0 - Live Sync & Diagnostics" "action.sh prints live sync banner"
assert_file_contains "$SB/action.out" "=== CoreSurface v1.3.0 Flagship Motion Diagnostic Report ===" "action.sh runs diagnostic report cleanly"

# Test uninstall.sh disarms active debug.coresurface.cfg and uninstalls CoreSurfaceEngine APK
printf 'debug.coresurface.cfg=motion=hyperos4;native=1;guard=1;thermallod=1;aod=1\n' > "$SB_PROPS_DB"
SB_PM_UNINST_LOG="$SB/pm_uninst.log"
: > "$SB_PM_UNINST_LOG"
cat > "$SB_BIN/pm" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SB_PM_UNINST_LOG"
exit 0
EOF
chmod +x "$SB_BIN/pm"

PATH="$SB_BIN:$PATH" CORESURFACE_MODDIR="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" \
  sh "$SB_MOD/uninstall.sh"
assert_file_contains "$SB_PROPS_DB" "debug.coresurface.cfg=motion=off;native=0;guard=0;thermallod=0;aod=0" "uninstall.sh disarms live Engine IPC"
assert_file_contains "$SB_PM_UNINST_LOG" "uninstall org.mystivara.coresurface.engine" "uninstall.sh cleanly uninstalls CoreSurfaceEngine APK"

# ---------------------------------------------------------------------------
printf '=== Test 19: Flagship Computility (Level 6/4) Re-Assertion, system/deviceLevelList & Non-LTPO AOD Keycode-Goto Flip ===\n'
setup_sandbox "t19_computility_and_aod_always"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
cat > "$SB_XML_DIR1/kunzite.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<features>
    <bool name="support_background_blur">false</bool>
    <integer name="device_level">1</integer>
    <bool name="support_aod">true</bool>
    <bool name="is_only_support_keycode_goto">true</bool>
    <bool name="support_screen_effect">true</bool>
</features>
EOF
printf 'CS_TIER_MODE=flagship\nFEAT_AOD_UNLOCK=1\n' > "$SB_STATE/config.prop"
printf 'persist.sys.computility.cpulevel=2\npersist.sys.computility.gpulevel=2\n' > "$SB_PROPS_DB"
printf 'system|deviceLevelList=v:1,c:2,g:2\n' > "$SB_SETTINGS_DB"
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

run_post_fs_data
assert_file_contains "$SB_PROPS_LOG" "persist.sys.computility.cpulevel=6" "Flagship sets persist.sys.computility.cpulevel=6"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.computility.gpulevel=6" "Flagship sets persist.sys.computility.gpulevel=6"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.computility.version=2025" "Flagship sets persist.sys.computility.version=2025"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.computilityV2.cpulevel=4" "Flagship sets persist.sys.computilityV2.cpulevel=4"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.computilityV2.gpulevel=4" "Flagship sets persist.sys.computilityV2.gpulevel=4"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.computilityV2.devicelevel=4" "Flagship sets persist.sys.computilityV2.devicelevel=4"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.hyper_transition_v=3" "Flagship sets persist.sys.hyper_transition_v=3"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.shell_anim_enable_fcb=true" "Flagship sets ro.miui.shell_anim_enable_fcb=true"
assert_file_contains "$SB_PROPS_LOG" "persist.hyper.barfollow_anim=true" "Flagship sets persist.hyper.barfollow_anim=true"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="is_only_support_keycode_goto">false</bool>' "Non-LTPO AOD flips is_only_support_keycode_goto true -> false to unlock Always/Scheduled"
assert_file_not_contains "$SB_STATE/work/device_features.xml" 'is_video_screen' "Non-LTPO AOD omits is_video_screen to prevent FOD fade-out white flash"
assert_file_not_contains "$SB_STATE/work/device_features.xml" 'support_aod_aon' "Non-LTPO AOD omits support_aod_aon to prevent AON Doze blink"
assert_file_not_contains "$SB_STATE/work/device_features.xml" 'support_hdr_hbm_brighten' "Flagship Suite omits panel HBM brighten override to prevent FOD white flash"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_screen_effect">true</bool>' "Protected stock display tag remains untouched"

# Simulate HyperOS ComputilityService resetting cpulevel & gpulevel back to 2 during boot
tmp_db="$SB_PROPS_DB.reverted"
awk -F '=' '$1 != "persist.sys.computility.cpulevel" && $1 != "persist.sys.computility.gpulevel" { print $0 }' "$SB_PROPS_DB" > "$tmp_db"
printf 'persist.sys.computility.cpulevel=2\npersist.sys.computility.gpulevel=2\n' >> "$tmp_db"
mv -f "$tmp_db" "$SB_PROPS_DB"

run_service
assert_file_contains "$SB_PROPS_DB" "persist.sys.computility.cpulevel=6" "service.sh re-asserts persist.sys.computility.cpulevel=6 after ComputilityService boot overwrite"
assert_file_contains "$SB_PROPS_DB" "persist.sys.computility.gpulevel=6" "service.sh re-asserts persist.sys.computility.gpulevel=6 after ComputilityService boot overwrite"
assert_file_contains "$SB_SETTINGS_DB" "system|deviceLevelList=v:1,c:3,g:3" "service.sh syncs settings system/deviceLevelList=v:1,c:3,g:3 for Control Center"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_ANIMATIONS=verified_active" "Verifier confirms FEAT_ANIMATIONS verified_active with computility level 6"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_AOD_UNLOCK=verified_active" "Verifier confirms FEAT_AOD_UNLOCK verified_active via is_only_support_keycode_goto=false"

# Verify uninstall cleanly restores original system/deviceLevelList=v:1,c:2,g:2
PATH="$SB_BIN:$PATH" CORESURFACE_MODDIR="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" \
  sh "$SB_MOD/uninstall.sh"
assert_file_contains "$SB_SETTINGS_DB" "system|deviceLevelList=v:1,c:2,g:2" "uninstall.sh restores original system/deviceLevelList cleanly"

# ---------------------------------------------------------------------------
printf '=== Test 20: Flagship Audio & Speaker Enhancement + Flagship Exclusive Porting Suite ===\n'
setup_sandbox "t20_flagship_audio_and_porting_suite"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
write_sample_xml "$SB_XML_DIR1/kunzite.xml"
printf 'CS_TIER_MODE=flagship\n' > "$SB_STATE/config.prop"
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

run_post_fs_data
# Lightweight HyperOS 3 Advanced Textures v4 contract on non-flagship (prevents -1 Screen black blink & GPU heat)
assert_file_contains "$SB_PROPS_LOG" "persist.sys.sf.disable_blurs=false" "Blur contract sets persist.sys.sf.disable_blurs=false"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.launcher_blur_supported=true" "Non-flagship HOS 3 omits launcher_blur_supported to prevent -1 Screen black blink"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.background_blur_setting=1" "Blur contract omits conflicting user-toggle background_blur_setting prop"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.advanced_visual_release=4" "HyperOS 3 Flagship sets native Advanced Textures release=4"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.mi_shadow_supported=true" "Non-flagship HOS 3 skips heavy mi_shadow shader to keep GPU cool"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.support_window_smoothcorner=true" "HyperOS 3 Flagship sets support_window_smoothcorner=true"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.support_view_smoothcorner=true" "HyperOS 3 Flagship sets support_view_smoothcorner=true"
assert_file_not_contains "$SB_PROPS_LOG" "ro.miui.backdrop_sampling_enabled=true" "Non-flagship HOS 3 skips heavy backdrop_sampling shader"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.add_blurnoise_supported=true" "Non-flagship HOS 3 skips heavy blurnoise shader"
# Audio & Speaker props
assert_file_contains "$SB_PROPS_LOG" "ro.vendor.audio.spk.stereo=true" "Flagship Audio sets ro.vendor.audio.spk.stereo=true"
assert_file_contains "$SB_PROPS_LOG" "ro.vendor.audio.spk.clean=true" "Flagship Audio sets ro.vendor.audio.spk.clean=true"
assert_file_contains "$SB_PROPS_LOG" "ro.vendor.audio.dolby.dax.support=true" "Flagship Audio sets ro.vendor.audio.dolby.dax.support=true"
assert_file_contains "$SB_PROPS_LOG" "ro.vendor.audio.sfx.scenario=true" "Flagship Audio sets ro.vendor.audio.sfx.scenario=true"
assert_file_contains "$SB_PROPS_LOG" "ro.vendor.audio.hifi=true" "Flagship Audio sets ro.vendor.audio.hifi=true"
assert_file_contains "$SB_PROPS_LOG" "persist.vendor.audio.hifi.int_codec=true" "Flagship Audio sets persist.vendor.audio.hifi.int_codec=true"
assert_file_contains "$SB_PROPS_LOG" "ro.audio.spatializer_enabled=true" "Flagship Audio sets ro.audio.spatializer_enabled=true"
# Audio XML tags
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_dolby">true</bool>' "Flagship Audio XML enables support_dolby"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_hifi">true</bool>' "Flagship Audio XML enables support_hifi"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_sound_assist">true</bool>' "Flagship Audio XML enables support_sound_assist"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_24bit_record">true</bool>' "Flagship Audio XML enables support_24bit_record"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_stereo_record">true</bool>' "Flagship Audio XML enables support_stereo_record"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_interview_record_param">true</bool>' "Flagship Audio XML enables studio interview mic mode"
# Flagship Porting Suite props
assert_file_contains "$SB_PROPS_LOG" "ro.miui.ui.font.animation=enable" "Flagship Suite sets ro.miui.ui.font.animation=enable"
assert_file_contains "$SB_PROPS_LOG" "ro.multiwin.fulldecor_support=true" "Flagship Suite sets ro.multiwin.fulldecor_support=true"
assert_file_contains "$SB_PROPS_LOG" "ro.product.camera.livephoto.support=3" "Flagship Suite sets ro.product.camera.livephoto.support=3"
assert_file_contains "$SB_PROPS_LOG" "ro.camera.sound.forced=0" "Flagship Suite allows muting camera shutter sound"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.power_mode_support=true" "Flagship Suite sets persist.sys.power_mode_support=true"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.launch_response_optimization.enable=true" "Flagship Suite sets persist.sys.launch_response_optimization.enable=true"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.support_ai_wakeup_effect=true" "Flagship Suite sets AI wakeup effect"
assert_file_contains "$SB_PROPS_LOG" "persist.vendor.night.charge=true" "Flagship Suite sets optimized Night Charge"
assert_file_contains "$SB_PROPS_LOG" "persist.vendor.battery.ai.predict=true" "Flagship Suite sets AI Battery Prediction"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.translate.state.supportAiSubtitles=true" "Flagship Suite sets supportAiSubtitles=true"
# Flagship Porting Suite XML tags
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_AI_display">true</bool>' "Flagship Suite XML enables support_AI_display"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_super_resolution">true</bool>' "Flagship Suite XML enables support_super_resolution"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_hdr_enhance">true</bool>' "Flagship Suite XML enables support_hdr_enhance"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="is_support_video_tool_box">true</bool>' "Flagship Suite XML enables is_support_video_tool_box"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_wild_boost">true</bool>' "Flagship Suite XML enables support_wild_boost"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_game_gunsight">true</bool>' "Flagship Suite XML enables support_game_gunsight"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_gallery_hdr">true</bool>' "Flagship Suite XML enables Gallery HDR"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="gallery_support_dolby">true</bool>' "Flagship Suite XML enables Gallery Dolby"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_local_ocr">true</bool>' "Flagship Suite XML enables on-device Local OCR"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_miplay_cast_privacy">true</bool>' "Flagship Suite XML enables MiPlay Cast Privacy"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_voip_record">true</bool>' "Flagship Suite XML enables VoIP Call Recording"
assert_file_contains "$SB_STATE/work/device_features.xml" '<integer name="support_inner_record">1</integer>' "Flagship Suite XML enables Internal Audio Recording"

run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_FLAGSHIP_AUDIO=verified_active" "Verifier marks FEAT_FLAGSHIP_AUDIO=verified_active"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_FLAGSHIP_SUITE=verified_active" "Verifier marks FEAT_FLAGSHIP_SUITE=verified_active"

# WebUI status & set whitelist
_t20_status=$(PATH="$SB_BIN:$PATH" CORESURFACE_MODDIR="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" status)
printf '%s\n' "$_t20_status" > "$SB/t20_status.out"
assert_file_contains "$SB/t20_status.out" "eff_feat_flagship_audio=1" "WebUI status reports eff_feat_flagship_audio=1"
assert_file_contains "$SB/t20_status.out" "eff_feat_flagship_suite=1" "WebUI status reports eff_feat_flagship_suite=1"
assert_file_contains "$SB/t20_status.out" "verify_feat_flagship_audio=verified_active" "WebUI status reports verify_feat_flagship_audio=verified_active"
assert_file_contains "$SB/t20_status.out" "verify_feat_flagship_suite=verified_active" "WebUI status reports verify_feat_flagship_suite=verified_active"

PATH="$SB_BIN:$PATH" CORESURFACE_MODDIR="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_FLAGSHIP_AUDIO 0 >/dev/null
assert_file_contains "$SB_STATE/config.prop" "FEAT_FLAGSHIP_AUDIO=0" "WebUI set accepts FEAT_FLAGSHIP_AUDIO=0"
PATH="$SB_BIN:$PATH" CORESURFACE_MODDIR="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_FLAGSHIP_SUITE 0 >/dev/null
assert_file_contains "$SB_STATE/config.prop" "FEAT_FLAGSHIP_SUITE=0" "WebUI set accepts FEAT_FLAGSHIP_SUITE=0"

# Lite tier: Audio ON by default, Porting Suite & Advanced Textures v4 OFF by default
setup_sandbox "t20b_lite_audio_on_suite_off"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "5500000"
write_sample_xml "$SB_XML_DIR1/kunzite.xml"
printf 'CS_TIER_MODE=low\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.advanced_visual_release=4" "Lite tier skips Advanced Textures v4 release=4"
assert_file_contains "$SB_PROPS_LOG" "ro.vendor.audio.spk.stereo=true" "Lite tier keeps Flagship Audio & Speaker ON by default"
assert_file_not_contains "$SB_PROPS_LOG" "ro.miui.ui.font.animation=enable" "Lite tier keeps heavy Flagship Porting Suite OFF by default"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_dolby">true</bool>' "Lite tier XML enables Audio support_dolby"
assert_file_not_contains "$SB_STATE/work/device_features.xml" '<bool name="support_wild_boost">true</bool>' "Lite tier XML skips Flagship Porting Suite tags"

# Native Flagship Passthrough (motion_only): skips both Audio & Porting Suite overrides
setup_sandbox "t20c_native_flagship_skips_audio_suite"
write_mock_getprop "OS3.0" "" "36" "1" "houji" "Xiaomi 15 Ultra"
write_mock_meminfo "15600000"
printf 'ro.miui.device_level=3\nro.surface_flinger.supports_background_blur=1\n' > "$SB_PROPS_DB"
cat > "$SB_XML_DIR1/houji.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<features>
    <bool name="support_background_blur">true</bool>
    <integer name="device_level">3</integer>
    <bool name="support_aod">true</bool>
</features>
EOF
printf 'CS_TIER_MODE=auto\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "ro.vendor.audio.spk.stereo=true" "Native Flagship motion_only skips Flagship Audio prop overrides"
assert_file_not_contains "$SB_PROPS_LOG" "ro.miui.ui.font.animation=enable" "Native Flagship motion_only skips Flagship Suite prop overrides"

# ---------------------------------------------------------------------------
printf '=== Test 21: HyperOS 4.0 (Android 17) Bionic Material & Never-Downgrade Visual Release ===\n'
setup_sandbox "t21_hyperos4_bionic_material"
write_mock_getprop "OS4.0" "" "37" "1" "malachite" "Redmi Note 16 Pro"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR1/malachite.xml"
printf 'CS_TIER_MODE=flagship\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_contains "$SB_PROPS_LOG" "persist.sys.advanced_visual_release=5" "HyperOS 4 Flagship sets native advanced_visual_release=5"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.bionic_material_supported=true" "HyperOS 4 Flagship enables persist.sys.bionic_material_supported=true"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.computility.cpulevel=6" "HyperOS 4 Flagship sets computility cpulevel=6"
assert_file_not_contains "$SB_STATE/os_bugs.state" "LEAKED_PERSIST_PROPS" "HyperOS 4 does not falsely flag native release=5 as leaked prop"

# Future HyperOS 4.1+ ROM with stock advanced_visual_release=6 must NEVER be downgraded to 5
setup_sandbox "t21b_hyperos4_never_downgrade_avr6"
write_mock_getprop "OS4.1" "" "37" "1" "malachite" "Redmi Note 16 Pro"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR1/malachite.xml"
printf 'persist.sys.advanced_visual_release=6\n' > "$SB_PROPS_DB"
printf 'CS_TIER_MODE=flagship\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_contains "$SB_PROPS_LOG" "persist.sys.advanced_visual_release=6" "HyperOS 4.1+ Never-Downgrade preserves stock advanced_visual_release=6"
assert_file_not_contains "$SB_STATE/os_bugs.state" "LEAKED_PERSIST_PROPS" "HyperOS 4.1+ release=6 is not flagged as leaked"

# ---------------------------------------------------------------------------
printf '=== Test 22: True Physics Engine (CoreSpringSolver ODE, Interruptibility, iOS Fluid vs ColorOS Quantum) ===\n'
setup_sandbox "t22_true_physics_engine"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
write_sample_xml "$SB_XML_DIR1/kunzite.xml"
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"

run_post_fs_data

# Live zero-Binder switch to distinct Bouncy & Snappy profiles (0 reboot!)
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" \
  sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_MOTION_PROFILE bouncy >/dev/null
assert_file_contains "$SB_PROPS_DB" "debug.coresurface.cfg=motion=bouncy;" "WebUI live switch pushes motion=bouncy zero-Binder IPC"
assert_file_not_contains "$SB_STATE/state.prop" "FEAT_MOTION_PROFILE" "Live Bouncy switch requires 0 reboot"

PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" \
  sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_MOTION_PROFILE snappy >/dev/null
assert_file_contains "$SB_PROPS_DB" "debug.coresurface.cfg=motion=snappy;" "WebUI live switch pushes motion=snappy zero-Binder IPC"

# Verifier accepts ShellTransitionPhysics / LauncherChoreography as genuine active motion hooks
cat > "$SB/sysui_wmshell_telem.prop" <<'EOF'
ENGINE_ACTIVE=1
ENGINE_MODE=NATIVE_MOTION
MOTION_PROFILE=snappy
DISPLAY_HZ=120
LOD_TIER=FULL
HOOKS_BOUND=ToastGuard,ShellTransitionPhysics,SystemUIChoreography
NATIVE_GATES=10
FOLME_HOOKS=4
SPRINGS_TUNED=18
CURVES_APPLIED=12
EOF
cat > "$SB/home_choreo_telem.prop" <<'EOF'
ENGINE_ACTIVE=1
ENGINE_MODE=NATIVE_MOTION
MOTION_PROFILE=snappy
DISPLAY_HZ=120
LOD_TIER=FULL
HOOKS_BOUND=RecentsGuard,LauncherChoreography
NATIVE_GATES=8
FOLME_HOOKS=3
SPRINGS_TUNED=24
CURVES_APPLIED=0
EOF
CORESURFACE_ENGINE_INSTALLED=1 \
CORESURFACE_ENGINE_SYSUI_TELEM="$SB/sysui_wmshell_telem.prop" \
CORESURFACE_ENGINE_HOME_TELEM="$SB/home_choreo_telem.prop" \
CORESURFACE_ENGINE_AOD_TELEM="$SB/missing_aod.prop" \
  run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_MOTION_PROFILE=verified_active" "Verifier marks FEAT_MOTION_PROFILE verified_active via WMShell + LauncherChoreography hooks"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_MOTION=snappy" "Verifier reports active snappy physics profile"

# Host JVM mathematical verification of CoreSpringSolver & MotionProfileSpec (exact ODE & unmistakable contrast)
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  _jdir="$SB/jvm_physics_test"
  mkdir -p "$_jdir/classes"
  cat > "$_jdir/PhysicsMathTest.java" <<'EOF'
import org.mystivara.coresurface.engine.CoreSpringSolver;
import org.mystivara.coresurface.engine.MotionProfileSpec;

public final class PhysicsMathTest {
    public static void main(String[] args) {
        // 1. Exact convergence across underdamped, critically damped, and overdamped regimes
        double[] zetas = new double[] { 0.66, 0.94, 1.20 };
        for (double z : zetas) {
            CoreSpringSolver s = new CoreSpringSolver(z, 0.34);
            s.reset(0.0, 1.0, 0.0);
            for (int i = 0; i < 240; i++) {
                s.step(1.0 / 120.0);
            }
            if (Math.abs(s.getPosition() - 1.0) > 0.005 || Double.isNaN(s.getPosition())) {
                throw new AssertionError("Failed convergence for zeta=" + z + " pos=" + s.getPosition());
            }
        }

        // 2. Unconditional stability under severe frame drop (dt = 50ms)
        CoreSpringSolver drop = new CoreSpringSolver(0.66, 0.38);
        drop.reset(0.0, 100.0, 250.0);
        for (int i = 0; i < 40; i++) {
            drop.step(0.050);
        }
        if (Math.abs(drop.getPosition() - 100.0) > 0.5 || Double.isNaN(drop.getPosition())) {
            throw new AssertionError("Frame-drop instability: pos=" + drop.getPosition());
        }

        // 3. True mid-flight interruptibility: retarget preserves exact position & velocity (C1 continuous)
        CoreSpringSolver intr = new CoreSpringSolver(0.88, 0.35);
        intr.reset(0.0, 100.0, 0.0);
        for (int i = 0; i < 8; i++) {
            intr.step(1.0 / 120.0);
        }
        double posBefore = intr.getPosition();
        double velBefore = intr.getVelocity();
        if (!(posBefore > 5.0 && velBefore > 50.0)) {
            throw new AssertionError("Spring not in motion before interrupt: pos=" + posBefore + " vel=" + velBefore);
        }
        intr.retarget(0.0);
        if (intr.getPosition() != posBefore || intr.getVelocity() != velBefore) {
            throw new AssertionError("Retarget broke C1 continuity");
        }
        for (int i = 0; i < 180; i++) {
            intr.step(1.0 / 120.0);
        }
        if (Math.abs(intr.getPosition()) > 0.25) {
            throw new AssertionError("Interrupted spring failed to settle to new target 0: " + intr.getPosition());
        }

        // 4. Genuine unmistakable contrast across Snappy, Fluid, and Bouncy (not subtle gimmick!)
        MotionProfileSpec snappy = MotionProfileSpec.forProfile("snappy", 120.0f, 1.0f);
        MotionProfileSpec fluid  = MotionProfileSpec.forProfile("fluid", 120.0f, 1.0f);
        MotionProfileSpec bouncy = MotionProfileSpec.forProfile("bouncy", 120.0f, 1.0f);

        if (!(snappy.shellSettleMs <= 260 && fluid.shellSettleMs >= 420)) {
            throw new AssertionError("Snappy vs Fluid must have wide settle contrast: snappy="
                    + snappy.shellSettleMs + "ms fluid=" + fluid.shellSettleMs + "ms");
        }
        if (!(bouncy.shellAllowOvershoot && bouncy.shellMaxOvershoot >= 1.05f && bouncy.appPosDamping <= 0.70f)) {
            throw new AssertionError("Bouncy must provide genuine visible elastic overshoot");
        }
        if (snappy.shellAllowOvershoot || fluid.shellAllowOvershoot) {
            throw new AssertionError("Snappy & Fluid must remain zero-overshoot");
        }
        if (!(snappy.folmeBlendWeight >= 0.80f && fluid.folmeBlendWeight >= 0.80f && bouncy.folmeBlendWeight >= 0.80f)) {
            throw new AssertionError("Active profiles must apply strong Folme blend weight (>=0.80)");
        }
        double snappyEarly = CoreSpringSolver.evaluateUnit(snappy.shellDamping, snappy.shellResponseSec, 0.10, snappy.shellInitialVelocity);
        double fluidEarly  = CoreSpringSolver.evaluateUnit(fluid.shellDamping, fluid.shellResponseSec, 0.10, fluid.shellInitialVelocity);
        if (!(snappyEarly - fluidEarly > 0.20)) {
            throw new AssertionError("Snappy must be dramatically ahead of Fluid at 100ms: " + snappyEarly + " vs " + fluidEarly);
        }

        // Verify real visible overshoot on Bouncy profile
        double maxBouncy = 0.0;
        for (int i = 1; i <= 120; i++) {
            double v = CoreSpringSolver.evaluateUnit(bouncy.shellDamping, bouncy.shellResponseSec, i / 120.0, bouncy.shellInitialVelocity);
            if (v > maxBouncy) maxBouncy = v;
        }
        if (!(maxBouncy >= 1.04)) {
            throw new AssertionError("Bouncy curve must visibly overshoot >= 4%: max=" + maxBouncy);
        }

        // 5. Verify pre-baked 65-sample LUT matches analytical ODE within 0.002 & exact endpoints
        if (snappy.sampleShellSpatial(0.0f) != 0.0f || snappy.sampleShellSpatial(1.0f) != 1.0f
                || bouncy.sampleShellSpatial(0.0f) != 0.0f || bouncy.sampleShellSpatial(1.0f) != 1.0f
                || bouncy.sampleShellMonotonic(1.0f) != 1.0f) {
            throw new AssertionError("Pre-baked LUT endpoints must be exact [0, 1]");
        }
        float maxLutBouncy = 0.0f;
        for (int i = 0; i <= 100; i++) {
            float u = i / 100.0f;
            float sVal = bouncy.sampleShellSpatial(u);
            float mVal = bouncy.sampleShellMonotonic(u);
            if (sVal > maxLutBouncy) maxLutBouncy = sVal;
            if (mVal > 1.0001f) {
                throw new AssertionError("Monotonic opacity LUT must NEVER overshoot 1.0: " + mVal);
            }
        }
        if (!(maxLutBouncy >= 1.04f)) {
            throw new AssertionError("Bouncy LUT must preserve visible overshoot >= 4%: " + maxLutBouncy);
        }

        // 6. Seamless backward-compatible legacy alias normalization
        if (!MotionProfileSpec.PROFILE_SNAPPY.equals(MotionProfileSpec.forProfile("coloros", 120.0f, 1.0f).profileId)
                || !MotionProfileSpec.PROFILE_SNAPPY.equals(MotionProfileSpec.forProfile("silk", 120.0f, 1.0f).profileId)
                || !MotionProfileSpec.PROFILE_FLUID.equals(MotionProfileSpec.forProfile("hyperos4", 120.0f, 1.0f).profileId)
                || !MotionProfileSpec.PROFILE_BOUNCY.equals(MotionProfileSpec.forProfile("ios", 120.0f, 1.0f).profileId)) {
            throw new AssertionError("Legacy aliases must map cleanly to snappy/fluid/bouncy");
        }
        System.out.println("PHYSICS_MATH_OK");
    }
}
EOF
  if javac --release 11 -d "$_jdir/classes" \
      "$REPO_ROOT/engine-src/java/org/mystivara/coresurface/engine/CoreSpringSolver.java" \
      "$REPO_ROOT/engine-src/java/org/mystivara/coresurface/engine/MotionProfileSpec.java" \
      "$_jdir/PhysicsMathTest.java" 2>"$_jdir/compile.err" \
    && java -cp "$_jdir/classes" PhysicsMathTest >"$_jdir/run.out" 2>&1; then
    assert_file_contains "$_jdir/run.out" "PHYSICS_MATH_OK" "CoreSpringSolver ODE, pre-baked LUT precision, mid-flight interruptibility & Snappy/Fluid/Bouncy contrast verified"
  else
    fail "CoreSpringSolver host JVM physics verification failed ($(cat "$_jdir/compile.err" "$_jdir/run.out" 2>/dev/null || true))"
  fi
fi

# ---------------------------------------------------------------------------
printf '=== Test 23: Zero-Hesitation App Launch Props, Persistent APK Signing & LSPosed Scope ===\n'
setup_sandbox "t23_launch_and_signing"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
write_sample_xml "$SB_XML_DIR1/kunzite.xml"
printf 'CS_TIER_MODE=flagship\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_contains "$SB_PROPS_LOG" "ro.launcher.blur.appLaunch=0" "Mid-range GPU disables Frame-0 app-launch blur stall (ro.launcher.blur.appLaunch=0)"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.launch_response_optimization.enable=true" "Launch response optimization enabled on Flagship tier"

# Lite tier also gets launch_response_optimization & appLaunch=0
setup_sandbox "t23b_lite_launch_opt"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "5500000"
write_sample_xml "$SB_XML_DIR1/kunzite.xml"
printf 'CS_TIER_MODE=low\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_contains "$SB_PROPS_LOG" "ro.launcher.blur.appLaunch=0" "Lite tier keeps ro.launcher.blur.appLaunch=0"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.launch_response_optimization.enable=true" "Lite tier also receives zero-cost launch response optimization"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.shell_anim_enable_fcb=true" "Lite tier receives zero-GPU-cost Frame Callback Booster (FCB)"

# Native flagship GPU (device_level=3) retains ro.launcher.blur.appLaunch=1
setup_sandbox "t23c_flagship_gpu_applaunch"
write_mock_getprop "OS3.0" "" "36" "1" "houji" "Xiaomi 15 Ultra"
write_mock_meminfo "15600000"
printf 'ro.miui.device_level=3\n' > "$SB_PROPS_DB"
write_sample_xml "$SB_XML_DIR1/houji.xml"
printf 'CS_TIER_MODE=flagship\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_contains "$SB_PROPS_LOG" "ro.launcher.blur.appLaunch=1" "Native flagship GPU (device_level=3) keeps ro.launcher.blur.appLaunch=1"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.multi_task.mask_blur_enable=true" "Native flagship GPU retains Recents mask blur"

# Persistent signing keystore reuse & dual LSPosed recommended scope metadata (when Android SDK present)
if [ -d /opt/android-sdk/build-tools ] || [ -n "${ANDROID_HOME:-}" ] || [ -n "${ANDROID_SDK_ROOT:-}" ]; then
  _ks_path="$SB/persistent_signing/coresurface-test.jks"
  _out1="$SB/apk_build_1"
  _out2="$SB/apk_build_2"
  _b1=$(CORESURFACE_KEYSTORE="$_ks_path" CORESURFACE_ENGINE_OUT="$_out1" sh "$REPO_ROOT/scripts/build_engine.sh")
  _b2=$(CORESURFACE_KEYSTORE="$_ks_path" CORESURFACE_ENGINE_OUT="$_out2" sh "$REPO_ROOT/scripts/build_engine.sh")
  _cert1=$(printf '%s\n' "$_b1" | sed -n 's/.*cert=\([0-9a-f]*\).*/\1/p')
  _cert2=$(printf '%s\n' "$_b2" | sed -n 's/.*cert=\([0-9a-f]*\).*/\1/p')
  assert_eq "$( [ -n "$_cert1" ] && [ "$_cert1" = "$_cert2" ] && printf 'same' || printf 'diff' )" "same" "Persistent CORESURFACE_KEYSTORE produces identical cert SHA-256 across consecutive builds"

  _zip_list=$(unzip -l "$_out2/CoreSurfaceEngine.apk")
  printf '%s\n' "$_zip_list" > "$SB/apk_files.txt"
  assert_file_contains "$SB/apk_files.txt" "assets/xposed_init" "Engine APK preserves legacy assets/xposed_init"
  assert_file_contains "$SB/apk_files.txt" "META-INF/xposed/scope.list" "Engine APK includes META-INF/xposed/scope.list for modern LSPosed forks"
  assert_file_not_contains "$SB/apk_files.txt" "META-INF/xposed/module.prop" "Engine APK omits module.prop so legacy IXposedHookLoadPackage stays active"
  unzip -p "$_out2/CoreSurfaceEngine.apk" META-INF/xposed/scope.list > "$SB/scope.list"
  assert_file_contains "$SB/scope.list" "com.android.systemui" "scope.list recommends com.android.systemui"
  assert_file_contains "$SB/scope.list" "com.miui.home" "scope.list recommends com.miui.home"
  assert_file_contains "$SB/scope.list" "com.mi.android.globallauncher" "scope.list recommends POCO Launcher (com.mi.android.globallauncher)"
  assert_file_contains "$SB/scope.list" "com.mi.android.globalminusscreen" "scope.list recommends Global -1 Screen App Vault (com.mi.android.globalminusscreen)"
  assert_file_contains "$SB/scope.list" "com.miui.personalassistant" "scope.list recommends China -1 Screen App Vault (com.miui.personalassistant)"
  assert_file_contains "$SB/scope.list" "com.miui.aod" "scope.list recommends com.miui.aod"
  assert_file_contains "$SB/scope.list" "com.android.settings" "scope.list recommends com.android.settings"
fi

# ---------------------------------------------------------------------------
printf '=== Test 24: v1.3.0 Release Metadata, English UI Localization, Zero Scale Hacks & Binder Circuit-Breaker ===\n'
setup_sandbox "t24_v130_english_and_binder_cb"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
write_sample_xml "$SB_XML_DIR1/kunzite.xml"

assert_file_contains "$REPO_ROOT/module.prop" "version=v1.3.0" "module.prop bumps version to v1.3.0"
assert_file_contains "$REPO_ROOT/module.prop" "versionCode=130" "module.prop bumps versionCode to 130"
assert_file_contains "$REPO_ROOT/webroot/index.html" '<html lang="en">' "WebUI declares English locale (lang=en)"
assert_file_contains "$REPO_ROOT/webroot/index.html" 'v1.3.0' "WebUI displays v1.3.0 badge"
assert_file_contains "$REPO_ROOT/customize.sh" 'SELECT CORESURFACE TIER MODE' "Volume-key installer prompts are in English"
assert_file_not_contains "$REPO_ROOT/lib/settings_tx.sh" 'window_animation_scale' "Engine never touches Developer Options window_animation_scale"
assert_file_not_contains "$REPO_ROOT/lib/settings_tx.sh" 'transition_animation_scale' "Engine never touches Developer Options transition_animation_scale"
assert_file_not_contains "$REPO_ROOT/lib/settings_tx.sh" 'animator_duration_scale' "Engine never touches Developer Options animator_duration_scale"

# Verify fast Binder circuit-breaker in lib/settings_tx.sh prevents 40+ wasted forks & log spam
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"
SB_SETTINGS_CALLS="$SB/settings_calls.log"
: > "$SB_SETTINGS_CALLS"
cat > "$SB_BIN/settings" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SB_SETTINGS_CALLS"
printf 'cmd: Failure calling service settings: Failed transaction (2147483646)\n' >&2
exit 1
EOF
chmod +x "$SB_BIN/settings"
rm -f "$SB_BIN/cmd" "$SB_BIN/su"

run_service
_call_cnt=$(wc -l < "$SB_SETTINGS_CALLS" | tr -d ' ')
assert_eq "$( [ "$_call_cnt" -ge 1 ] && [ "$_call_cnt" -le 4 ] && printf 'fast' || printf 'unexpected:%s' "$_call_cnt" )" "fast" "Binder circuit-breaker stops wasted settings subprocess retries (1..4 calls total)"
assert_file_contains "$SB_STATE/coresurface.log" "using zero-Binder debug.coresurface.cfg bridge" "Settings TX logs clean single-line zero-Binder bridge fallback"
assert_file_not_contains "$SB_STATE/coresurface.log" "WARN: settings get" "Settings TX does not spam WARN lines on Android 15/16 root Binder block"

# ---------------------------------------------------------------------------
printf '=== Test 25: Full-Stack Lightness, Audio Never-Downgrade, Balanced Pro Parallel Sweep & -1 Screen Telemetry ===\n'
setup_sandbox "t25_fullstack_perfection"
write_mock_getprop "OS3.0" "" "36" "1" "kunzite" "Redmi Note 15 5G"
write_mock_meminfo "7500000"
write_sample_xml "$SB_XML_DIR1/kunzite.xml"
printf 'ro.vendor.audio.soundfx.type=dolby\n' > "$SB_PROPS_DB"
printf 'CS_TIER_MODE=flagship\n' > "$SB_STATE/config.prop"
run_post_fs_data

assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.multi_task.mask_blur_enable=true" "Mid-range GPU omits heavy Recents mask blur even on Flagship tier"
assert_file_not_contains "$SB_PROPS_LOG" "ro.vendor.audio.soundfx.type=mi" "Audio Never-Downgrade preserves factory stock ro.vendor.audio.soundfx.type=dolby"
assert_file_contains "$SB_PROPS_LOG" "ro.vendor.audio.sfx.independentequalizer=true" "Flagship Audio unlocks zero-overhead 10-band Graphic EQ"
assert_file_contains "$SB_PROPS_LOG" "ro.vendor.audio.sfx.earadj=true" "Flagship Audio unlocks earphone acoustic calibration"
assert_file_contains "$SB_PROPS_LOG" "ro.vendor.audio.game.effect=true" "Flagship Audio unlocks Game Turbo audio enhancement"
assert_file_contains "$SB_PROPS_LOG" "persist.vendor.audio.misound.disable=false" "Flagship Audio ensures Mi Sound pipeline is active"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_sound_effect">true</bool>' "Flagship Audio XML enables support_sound_effect"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_spatial_audio">true</bool>' "Flagship Audio XML enables support_spatial_audio"

# Verify balanced_pro receives zero-cost parallel_sweep & FCB
setup_sandbox "t25b_balanced_pro_parallel"
write_mock_getprop "OS3.0" "" "36" "1" "emerald" "Redmi Note 15 Pro"
write_mock_meminfo "7500000"
write_sample_xml "$SB_XML_DIR1/emerald.xml"
printf 'CS_TIER_MODE=balanced_pro\n' > "$SB_STATE/config.prop"
run_post_fs_data
assert_file_contains "$SB_PROPS_LOG" "persist.sys.enable_parallel_sweep=true" "Balanced Pro receives zero-GPU-cost parallel gesture interruptibility"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.shell_anim_enable_fcb=true" "Balanced Pro receives Frame Callback Booster (FCB)"

# Verify App Vault (-1 Screen) telemetry is aggregated by single-pass POSIX verifier
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
printf '4242\n'
exit 0
EOF
chmod +x "$SB_BIN/pidof"
cat > "$SB/minusone_telem.prop" <<'EOF'
ENGINE_ACTIVE=1
ENGINE_MODE=NATIVE_MOTION
MOTION_PROFILE=snappy
DISPLAY_HZ=120
LOD_TIER=FULL
HOOKS_BOUND=MinusOneGuard
BUGS_MITIGATED=HOS3_MINUS_ONE_BLACK
RECENTS_GUARDED=5
EOF
CORESURFACE_ENGINE_INSTALLED=1 \
CORESURFACE_ENGINE_SYSUI_TELEM="$SB/missing_sysui.prop" \
CORESURFACE_ENGINE_HOME_TELEM="$SB/missing_home.prop" \
CORESURFACE_ENGINE_MINUSONE_TELEM="$SB/minusone_telem.prop" \
CORESURFACE_ENGINE_AOD_TELEM="$SB/missing_aod.prop" \
CORESURFACE_ENGINE_SETTINGS_TELEM="$SB/missing_settings.prop" \
  run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_HOOKS=MinusOneGuard" "Verifier aggregates App Vault (-1 Screen) MinusOneGuard telemetry"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_ENGINE_BUGS=HOS3_MINUS_ONE_BLACK" "Verifier surfaces HOS3_MINUS_ONE_BLACK mitigation from App Vault"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_SURGICAL_GUARD=verified_active" "Verifier marks Surgical Guard verified_active via MinusOneGuard"

# ---------------------------------------------------------------------------
printf '\nResults: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
