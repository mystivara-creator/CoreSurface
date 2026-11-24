#!/bin/sh
# CoreSurface v1.0.0 - Host Unit Test Suite (Pure POSIX sh)
# Mocks getprop, resetprop, pidof, sleep, and /proc/meminfo in isolated temp sandboxes.

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
  SB_MEMINFO="$SB/meminfo"
  SB_CF_DIR="$SB/cfae_framework"

  mkdir -p "$SB_BIN" "$SB_MOD" "$SB_STATE"
  : > "$SB_PROPS_LOG"

  # Copy module runtime files into isolated MODDIR
  cp -R "$REPO_ROOT/lib" "$REPO_ROOT/defaults" "$REPO_ROOT/post-fs-data.sh" "$REPO_ROOT/service.sh" "$REPO_ROOT/uninstall.sh" "$SB_MOD/"

  # Fast no-op sleep mock so watchdog tests finish instantaneously
  cat > "$SB_BIN/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$SB_BIN/sleep"

  # Strict resetprop mock: MUST receive -n as first argument
  cat > "$SB_BIN/resetprop" <<EOF
#!/bin/sh
if [ "\${1:-}" != "-n" ]; then
  printf 'NON_PERSIST_VIOLATION:%s\n' "\$*" >> "$SB_PROPS_LOG"
  exit 99
fi
shift
printf '%s=%s\n' "\${1:-}" "\${2:-}" >> "$SB_PROPS_LOG"
exit 0
EOF
  chmod +x "$SB_BIN/resetprop"
}

write_mock_getprop() {
  _hos=$1
  _miui=$2
  _sdk=$3
  _boot=${4:-1}
  cat > "$SB_BIN/getprop" <<EOF
#!/bin/sh
case "\${1:-}" in
  ro.mi.os.version.name) printf '%s\n' "$_hos" ;;
  ro.miui.ui.version.name) printf '%s\n' "$_miui" ;;
  ro.build.version.sdk) printf '%s\n' "$_sdk" ;;
  sys.boot_completed) printf '%s\n' "$_boot" ;;
  *) printf '\n' ;;
esac
EOF
  chmod +x "$SB_BIN/getprop"
}

write_mock_meminfo() {
  _kb=$1
  printf 'MemTotal:       %s kB\nMemFree:        1024000 kB\n' "$_kb" > "$SB_MEMINFO"
}

run_post_fs_data() {
  PATH="$SB_BIN:$PATH" \
  CORESURFACE_MODDIR="$SB_MOD" \
  CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" \
  sh "$SB_MOD/post-fs-data.sh"
}

run_service() {
  PATH="$SB_BIN:$PATH" \
  CORESURFACE_MODDIR="$SB_MOD" \
  CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" \
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

# Boot 1: 0 -> 1
run_post_fs_data
assert_eq "$(cat "$SB_STATE/boot_strikes")" "1" "Boot 1 increments boot_strikes to 1"
assert_eq "$( [ -f "$SB_MOD/disable" ] && printf 'yes' || printf 'no' )" "no" "Module still enabled after strike 1"

# Boot 2: 1 -> 2
run_post_fs_data
assert_eq "$(cat "$SB_STATE/boot_strikes")" "2" "Boot 2 increments boot_strikes to 2"
assert_eq "$( [ -f "$SB_MOD/disable" ] && printf 'yes' || printf 'no' )" "no" "Module still enabled during strike 2 boot"

# Boot 3: sees boot_strikes >= 2 -> fail-closed disable
: > "$SB_PROPS_LOG"
run_post_fs_data
_rc=$?
assert_eq "$_rc" "0" "Strike >= 2 exits 0 cleanly"
assert_eq "$( [ -f "$SB_MOD/disable" ] && printf 'yes' || printf 'no' )" "yes" "Strike >= 2 creates disable file"
assert_eq "$(cat "$SB_STATE/boot_strikes")" "0" "Strike >= 2 resets boot_strikes to 0"
assert_eq "$(wc -l < "$SB_PROPS_LOG" | tr -d ' ')" "0" "Strike >= 2 applies zero properties"
assert_file_contains "$SB_STATE/state.prop" "WATCHDOG_STATUS=safe_mode_disabled" "State records safe_mode_disabled"

# ---------------------------------------------------------------------------
printf '=== Test 3: Watchdog service.sh Grace Window + Stable SystemUI ===\n'
setup_sandbox "t3_sysui_grace_healthy"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "8000000"
run_post_fs_data
assert_eq "$(cat "$SB_STATE/boot_strikes")" "1" "Preflight sets boot_strikes=1"

# Mock pidof: empty on calls 1-2 (grace window), then stable PID 4242
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
# 5a: < 6 GB (4 GB)
setup_sandbox "t5_ram_low"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "4096000"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "NON_PERSIST_VIOLATION" "4GB: all resetprop calls use -n"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.device_level=2" "4GB: Tier 1 sets device_level=2"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.deviceLevelList=v:1,c:2,g:2" "4GB: Tier 1 sets low deviceLevelList"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.background_blur_supported=true" "4GB: heavy blur skipped on < 6 GB"
assert_file_not_contains "$SB_PROPS_LOG" "ro.config.low_ram=false" "4GB: Tier 2 default OFF"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.hyperai_enabled=true" "4GB: Tier 3 default OFF"

# 5b: 6-7 GB (6 GB)
setup_sandbox "t5_ram_mid"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "6000000"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "NON_PERSIST_VIOLATION" "6GB: all resetprop calls use -n"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.deviceLevelList=v:1,c:2,g:3" "6GB: Tier 1 sets mid deviceLevelList"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.background_blur_supported=true" "6GB: heavy blur enabled on 6-7 GB"
assert_file_not_contains "$SB_PROPS_LOG" "ro.config.low_ram=false" "6GB: Tier 2 default OFF"

# 5c: >= 8 GB (8 GB)
setup_sandbox "t5_ram_high"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "7800000"
run_post_fs_data
assert_file_not_contains "$SB_PROPS_LOG" "NON_PERSIST_VIOLATION" "8GB: all resetprop calls use -n"
assert_file_contains "$SB_PROPS_LOG" "ro.miui.device_level=3" "8GB: Tier 1 sets flagship device_level=3"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.deviceLevelList=v:1,c:3,g:3" "8GB: Tier 1 sets flagship deviceLevelList"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.background_blur_supported=true" "8GB: heavy blur enabled"
assert_file_contains "$SB_PROPS_LOG" "ro.config.low_ram=false" "8GB: Tier 2 default ON"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.miui_freeform_max_count=4" "8GB: Tier 2 freeform relaxation ON"
assert_file_not_contains "$SB_PROPS_LOG" "persist.sys.hyperai_enabled=true" "8GB: Tier 3 remains OFF by default"

# ---------------------------------------------------------------------------
printf '=== Test 6: Tier 3 Explicit Opt-in & Version Gate ===\n'
setup_sandbox "t6_tier3_optin"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "7800000"
cat > "$SB_STATE/config.prop" <<'EOF'
TIER1_VISUAL=auto
TIER2_MULTITASK=auto
TIER3_EXPERIMENTAL=1
TIER3_HYPERAI=1
TIER3_AOD_UNLOCK=1
EOF
run_post_fs_data
assert_file_contains "$SB_PROPS_LOG" "persist.sys.hyperai_enabled=true" "Tier 3 opt-in enables HyperAI on HyperOS SDK 35"
assert_file_contains "$SB_PROPS_LOG" "persist.sys.aod_limit_disabled=true" "Tier 3 opt-in enables AOD unlock"

# ---------------------------------------------------------------------------
printf '=== Test 7: WebUI Control Script & Passive CoreFlow Detection ===\n'
setup_sandbox "t7_webui_ctl"
write_mock_getprop "OS2.0" "" "35" "1"
write_mock_meminfo "7800000"
mkdir -p "$SB_CF_DIR"

# Mock pidof reporting coreflowd running
cat > "$SB_BIN/pidof" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "coreflowd" ]; then
  printf '9999\n'
  exit 0
fi
exit 1
EOF
chmod +x "$SB_BIN/pidof"

_status_out=$(PATH="$SB_BIN:$PATH" \
  CORESURFACE_STATE_DIR="$SB_STATE" \
  CORESURFACE_MEMINFO="$SB_MEMINFO" \
  CORESURFACE_COREFLOW_DIR="$SB_CF_DIR" \
  sh "$SB_MOD/lib/webui_ctl.sh" status)

printf '%s\n' "$_status_out" > "$SB/status.out"
assert_file_contains "$SB/status.out" "coreflow_guard=active" "WebUI detects active CoreFlow Thermal Guard"
assert_file_contains "$SB/status.out" "ram_tier=high" "WebUI reports high RAM tier"

# Test config set valid + invalid
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set TIER3_EXPERIMENTAL 1 >/dev/null
assert_file_contains "$SB_STATE/config.prop" "TIER3_EXPERIMENTAL=1" "WebUI ctl saves TIER3_EXPERIMENTAL=1"

if PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" set BAD_KEY 1 >/dev/null 2>&1; then
  fail "WebUI ctl should reject unknown key"
else
  pass "WebUI ctl rejects unknown config key"
fi

# Test reset-safemode with auto-resolved MODDIR (no CORESURFACE_MODDIR env)
: > "$SB_MOD/disable"
printf '2\n' > "$SB_STATE/boot_strikes"
PATH="$SB_BIN:$PATH" CORESURFACE_STATE_DIR="$SB_STATE" sh "$SB_MOD/lib/webui_ctl.sh" reset-safemode >/dev/null
assert_eq "$( [ -f "$SB_MOD/disable" ] && printf 'yes' || printf 'no' )" "no" "reset-safemode removes auto-resolved MODDIR/disable"
assert_eq "$(cat "$SB_STATE/boot_strikes")" "0" "reset-safemode resets boot_strikes=0"

# ---------------------------------------------------------------------------
printf '\nResults: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
