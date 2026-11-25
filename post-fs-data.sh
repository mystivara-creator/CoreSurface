#!/system/bin/sh
# CoreSurface v1.0.0 - Early Boot Stage (post-fs-data)
# Pure user-space: non-persistent resetprop -n + fail-closed dynamic XML bind-mount + RRO guard.

MODDIR=${CORESURFACE_MODDIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}

# shellcheck source=lib/detect.sh
. "$MODDIR/lib/detect.sh"
# shellcheck source=lib/watchdog.sh
. "$MODDIR/lib/watchdog.sh"
# shellcheck source=lib/props.sh
. "$MODDIR/lib/props.sh"
# shellcheck source=lib/xml_patcher.sh
. "$MODDIR/lib/xml_patcher.sh"
# shellcheck source=lib/rro.sh
. "$MODDIR/lib/rro.sh"

CS_CONFIG_FILE="$CS_STATE_DIR/config.prop"

cs_watchdog_init_dir || exit 0

# Layer 1: ROM & SDK Gate
if ! cs_detect_rom; then
  : > "$CS_PROPS_AUDIT_FILE"
  cs_clear_system_prop "$MODDIR"
  cs_rro_clear "$MODDIR" || true
  cs_state_set "WATCHDOG_STATUS" "unsupported_rom"
  cs_state_set "WATCHDOG_REASON" "non_hyperos_or_miui_rom"
  cs_state_set "ROM_FAMILY" "unsupported"
  cs_state_set "ANDROID_SDK" "$CS_ANDROID_SDK"
  cs_state_set "XML_STATUS" "skipped"
  cs_state_set "XML_REASON" "unsupported_rom"
  cs_state_set "RRO_STATUS" "skipped"
  cs_log "ROM Gate: non-HyperOS/MIUI ROM (SDK=${CS_ANDROID_SDK}). Exiting cleanly with 0 properties applied."
  exit 0
fi

# Layer 3 (Preflight): Bootloop Watchdog Strike Check
cs_watchdog_preflight "$MODDIR"
_cs_pf_rc=$?
if [ "$_cs_pf_rc" -ne 0 ]; then
  # Strike >= 2 triggered Safe-Mode disable: clear system.prop and staged RRO overlays fail-closed
  cs_clear_system_prop "$MODDIR"
  cs_rro_clear "$MODDIR" || true
  cs_state_set "XML_STATUS" "skipped"
  cs_state_set "XML_REASON" "safe_mode_disabled"
  cs_state_set "RRO_STATUS" "disabled"
  exit 0
fi

# Layer 2: Dynamic Hardware / RAM Tiering
cs_detect_ram_tier

if [ ! -f "$CS_CONFIG_FILE" ] && [ -r "$MODDIR/defaults/config.prop" ]; then
  cp "$MODDIR/defaults/config.prop" "$CS_CONFIG_FILE" 2>/dev/null || true
fi

cs_load_config "$CS_CONFIG_FILE"
cs_resolve_features

cs_state_set "ROM_FAMILY" "$CS_ROM_FAMILY"
cs_state_set "ROM_VERSION" "$CS_ROM_VERSION"
cs_state_set "ANDROID_SDK" "$CS_ANDROID_SDK"
cs_state_set "RAM_MB" "$CS_RAM_MB"
cs_state_set "RAM_TIER" "$CS_RAM_TIER"
cs_state_set "DETECTED_TIER" "$CS_DETECTED_TIER"
cs_state_set "EFF_TIER" "$CS_EFF_TIER"
cs_state_set "PENDING_KEYS" ""

cs_log "Detected ${CS_ROM_FAMILY} (${CS_ROM_VERSION}) SDK=${CS_ANDROID_SDK} RAM=${CS_RAM_MB}MB | Tier=${CS_EFF_TIER} (cfg=${CFG_TIER_MODE}, detected=${CS_DETECTED_TIER})."

# Layer 4a: Apply Granular Non-Persistent Properties (resetprop -n + system.prop sync)
cs_apply_all_props "$MODDIR" || true

# Layer 4b: Dynamic device_features XML Patcher (fail-closed bind-mount)
cs_xml_apply || true

# Layer 4c: Keep clean-room RRO overlay staging synchronized with active config
cs_rro_stage "$MODDIR" || true

exit 0
