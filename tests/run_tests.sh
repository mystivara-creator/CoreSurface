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

  cp -R "$REPO_ROOT/lib" "$REPO_ROOT/defaults" "$REPO_ROOT/post-fs-data.sh" "$REPO_ROOT/service.sh" "$REPO_ROOT/uninstall.sh" "$SB_MOD/"

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

  # Strict resetprop mock: MUST receive -n as first argument, and updates live_props.db
  cat > "$SB_BIN/resetprop" <<EOF
#!/bin/sh
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
  cat > "$SB_BIN/getprop" <<EOF
#!/bin/sh
k=\${1:-}
case "\$k" in
  ro.mi.os.version.name) printf '%s\n' "$_hos" ; exit 0 ;;
  ro.miui.ui.version.name) printf '%s\n' "$_miui" ; exit 0 ;;
  ro.build.version.sdk) printf '%s\n' "$_sdk" ; exit 0 ;;
  sys.boot_completed) printf '%s\n' "$_boot" ; exit 0 ;;
  ro.product.device) printf '%s\n' "$_dev" ; exit 0 ;;
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
printf '=== Test 5: Dynamic RAM Tiering (<6GB, 6-7GB, >=8GB) & Mandatory resetprop -n ===\n'
setup_sandbox "t5_ram_low"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "4096000"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "NON_PERSIST_VIOLATION" "4GB: all resetprop calls use -n"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.device_level=2" "4GB: FEAT_ANIMATIONS sets device_level=2"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.background_blur_supported=true" "4GB: FEAT_BLUR auto OFF on < 6 GB"
assert_file_not_contains "$SB_PROPS_LOG" "ro.config.low_ram=false" "4GB: FEAT_MULTITASK auto OFF"

setup_sandbox "t5_ram_mid"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "6000000"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "NON_PERSIST_VIOLATION" "6GB: all resetprop calls use -n"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.deviceLevelList=v:1,c:2,g:3" "6GB: FEAT_ANIMATIONS sets mid deviceLevelList"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.background_blur_supported=true" "6GB: FEAT_BLUR auto ON on 6-7 GB"
assert_file_not_contains "$SB_PROPS_LOG" "ro.config.low_ram=false" "6GB: FEAT_MULTITASK auto OFF"

setup_sandbox "t5_ram_high"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "7800000"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "NON_PERSIST_VIOLATION" "8GB: all resetprop calls use -n"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.device_level=3" "8GB: FEAT_ANIMATIONS sets flagship device_level=3"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.background_blur_supported=true" "8GB: FEAT_BLUR auto ON"
assert_file_contains "$SB_PROPS_LOG" "ro.config.low_ram=false" "8GB: FEAT_MULTITASK auto ON"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.support_high_refresh_rate=true" "8GB: FEAT_DISPLAY_HZ auto ON"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.hyperai_enabled=true" "8GB: FEAT_HYPERAI remains OFF by default"

# ---------------------------------------------------------------------------
printf '=== Test 6: Dynamic device_features XML Patcher (Non-Destructive, SELinux, Fail-Closed) ===\n'
# 6a: Runtime ro.product.device auto-discovery + non-destructive patch + SELinux + bind-mount
setup_sandbox "t6_xml_happy"
write_mock_getprop "OS2.0" "" "35" "1" "aurora"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR2/aurora.xml"
run_post_fs_data
assert_file_contains "$SB_STATE/state.prop" "XML_STATUS=mounted" "XML patcher mounts discovered runtime device XML"
assert_file_contains "$SB_STATE/state.prop" "XML_SOURCE=$SB_XML_DIR2/aurora.xml" "XML patcher records exact discovered source path"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_background_blur">true</bool>' "XML patcher upgrades <bool> false -> true"
assert_file_contains "$SB_STATE/work/device_features.xml" '<integer name="device_level">3</integer>' "XML patcher upgrades lower <integer> 1 -> 3"
assert_file_contains "$SB_STATE/work/device_features.xml" '<bool name="support_aod">false</bool>' "XML patcher does NOT touch AOD tag when FEAT_AOD_UNLOCK=0"
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
cat > "$SB_STATE/config.prop" <<'EOF'
FEAT_BLUR=auto
FEAT_ANIMATIONS=auto
FEAT_XML_PATCHER=auto
FEAT_MULTITASK=auto
FEAT_DISPLAY_HZ=auto
FEAT_HYPERAI=1
FEAT_AOD_UNLOCK=1
EOF
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
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_DISPLAY_HZ=ignored_by_rom" "Verifier detects ROM-overridden FEAT_DISPLAY_HZ as ignored_by_rom"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_HYPERAI=disabled" "Verifier marks opt-in OFF feature as disabled"
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

# Seed initial vendor settings: disable_window_blurs=1, enable_freeform_support is absent (null)
printf 'global|disable_window_blurs=1\n' > "$SB_SETTINGS_DB"

run_post_fs_data
run_service
assert_file_contains "$SB_SETTINGS_LOG" "--user 0 get global disable_window_blurs" "Settings TX reads via --user 0"
assert_file_contains "$SB_SETTINGS_LOG" "--user 0 put global disable_window_blurs 0" "Settings TX writes via --user 0"
assert_file_contains "$SB_SETTINGS_DB" "global|disable_window_blurs=0" "Settings TX applies disable_window_blurs=0 for FEAT_BLUR"
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
FEAT_HYPERAI=0
FEAT_AOD_UNLOCK=0
EOF
run_service
assert_file_contains "$SB_SETTINGS_DB" "global|disable_window_blurs=1" "Disabling FEAT_BLUR restores original disable_window_blurs=1"
assert_file_not_contains "$SB_SETTINGS_DB" "global|enable_freeform_support=" "Disabling FEAT_MULTITASK deletes key whose original was null"
assert_file_contains "$SB_SETTINGS_LOG" "--user 0 delete global enable_freeform_support" "Settings TX deletes null-original key via --user 0"

# Verify uninstall.sh rolls back remaining keys and cleans state dir
assert_file_contains "$SB_SETTINGS_DB" "system|miui_refresh_rate_adaptive=1" "FEAT_DISPLAY_HZ setting active before uninstall"
PATH="$SB_BIN:$PATH" CORESURFACE_MODDIR="$SB_MOD" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/uninstall.sh"
assert_file_not_contains "$SB_SETTINGS_DB" "system|miui_refresh_rate_adaptive=" "uninstall.sh rolls back remaining settings before deleting state"
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

# Test granular key whitelist (valid + invalid)
for _gk in FEAT_BLUR FEAT_ANIMATIONS FEAT_XML_PATCHER FEAT_RRO_OVERLAYS FEAT_MULTITASK FEAT_DISPLAY_HZ; do
  PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set "$_gk" 0 >/dev/null
  assert_file_contains "$SB_STATE/config.prop" "${_gk}=0" "WebUI accepts granular key ${_gk}=0"
done
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_HYPERAI 1 >/dev/null
assert_file_contains "$SB_STATE/config.prop" "FEAT_HYPERAI=1" "WebUI accepts FEAT_HYPERAI=1"
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_AOD_UNLOCK 1 >/dev/null
assert_file_contains "$SB_STATE/config.prop" "FEAT_AOD_UNLOCK=1" "WebUI accepts FEAT_AOD_UNLOCK=1"

if PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_HYPERAI auto >/dev/null 2>&1; then
  fail "WebUI should reject 'auto' for opt-in FEAT_HYPERAI"
else
  pass "WebUI rejects 'auto' for opt-in FEAT_HYPERAI"
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
printf '=== Test 10: Clean-Room RRO Staging, Fail-Closed Clear, Verifier & HyperOS 3 Prop Audit ===\n'
setup_sandbox "t10_rro_and_hos3"
write_mock_getprop "OS3.0" "" "36" "1" "aurora"
write_mock_meminfo "7800000"
write_sample_xml "$SB_XML_DIR1/aurora.xml"

# Seed dummy compiled RRO APKs into $SB_MOD/overlays/
mkdir -p "$SB_MOD/overlays"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceSystemUI.apk"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceSystemUILiteBlur.apk"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceThemeManager.apk"
printf 'apk' > "$SB_MOD/overlays/CoreSurfaceMiWallpaper.apk"

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
  exit 0
fi
exit 1
EOF
chmod +x "$SB_BIN/cmd"

run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.advanced_visual_release=" "HyperOS 3 skips dropped legacy persist.sys.advanced_visual_release"
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceSystemUI.apk" ] && printf 'yes' || printf 'no' )" "yes" "RRO stages CoreSurfaceSystemUI.apk on >= 6 GB RAM"
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceSystemUILiteBlur.apk" ] && printf 'yes' || printf 'no' )" "no" "RRO skips LiteBlur overlay when full FEAT_BLUR is active"
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceThemeManager.apk" ] && printf 'yes' || printf 'no' )" "yes" "RRO stages CoreSurfaceThemeManager.apk"
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceMiWallpaper.apk" ] && printf 'yes' || printf 'no' )" "yes" "RRO stages CoreSurfaceMiWallpaper.apk"

run_service
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_BLUR=verified_active" "HyperOS 3 FEAT_BLUR achieves 100% verified_active"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_FEAT_RRO_OVERLAYS=verified_active" "Verifier marks active RRO overlays via cmd overlay list as verified_active"
assert_file_contains "$SB_STATE/verify.state" "VERIFY_RRO_ACTIVE=3" "Verifier counts 3/3 active RRO overlays"

# Turning FEAT_RRO_OVERLAYS=0 via webui_ctl immediately unstages RRO APKs for next boot
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_RRO_OVERLAYS 0 >/dev/null
assert_eq "$( [ -d "$SB_MOD/system/product/overlay" ] && printf 'exists' || printf 'cleared' )" "cleared" "Setting FEAT_RRO_OVERLAYS=0 clears staged overlays for next boot"

# Turning FEAT_RRO_OVERLAYS=1 + FEAT_BLUR=0 stages LiteBlur overlay
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_BLUR 0 >/dev/null
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" CORESURFACE_MEMINFO="$SB_MEMINFO" sh "$SB_MOD/lib/webui_ctl.sh" set FEAT_RRO_OVERLAYS 1 >/dev/null
assert_eq "$( [ -f "$SB_MOD/system/product/overlay/CoreSurfaceSystemUILiteBlur.apk" ] && printf 'yes' || printf 'no' )" "yes" "Enabling RRO with FEAT_BLUR=0 stages CoreSurfaceSystemUILiteBlur.apk"

# Watchdog Safe-Mode (boot_strikes=2) clears staged RRO APKs fail-closed
printf '2\n' > "$SB_STATE/boot_strikes"
run_post_fs_data
assert_eq "$( [ -d "$SB_MOD/system/product/overlay" ] && printf 'exists' || printf 'cleared' )" "cleared" "Watchdog Safe-Mode clears staged RRO overlays fail-closed"

# ---------------------------------------------------------------------------
printf '\nResults: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
