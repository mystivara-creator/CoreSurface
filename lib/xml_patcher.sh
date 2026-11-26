#!/system/bin/sh
# CoreSurface - Dynamic device_features XML Patcher (Fail-Closed Bind-Mount)
# Pure POSIX sh + awk. Zero hardcoded device codenames.
# Rules:
#   - Non-destructive / Add-Only: <bool> only upgraded false -> true; <integer> never lowered.
#   - Never touches display color, fpsList/refresh rate, or double_tap touch sensor tags.
#   - Preserves SELinux context (chcon --reference) before bind-mount so Settings/AOD can read it.

CS_XML_WORK_DIR="$CS_STATE_DIR/work"
CS_XML_WORK_FILE="$CS_XML_WORK_DIR/device_features.xml"
CS_XML_PATCH_LIST="$CS_STATE_DIR/xml_patched_tags.list"
CS_XML_DEFAULT_DIRS="/mi_ext/product/etc/device_features:/product/etc/device_features:/system/etc/device_features:/vendor/etc/device_features"

cs_xml_is_valid_features_xml() {
  _cs_xv_file=$1
  [ -r "$_cs_xv_file" ] && [ -s "$_cs_xv_file" ] || return 1
  grep -q '<features' "$_cs_xv_file" 2>/dev/null || return 1
  grep -q '</features>' "$_cs_xv_file" 2>/dev/null || return 1
  return 0
}

# Dynamically discover device_features XML via runtime `getprop ro.product.device`,
# falling back to the first valid .xml in standard HyperOS/MIUI search paths.
# Sets: CS_XML_DISCOVERED
cs_xml_discover() {
  CS_XML_DISCOVERED=""
  export CS_XML_DISCOVERED

  _cs_dev=$(cs_getprop "ro.product.device")
  _cs_dirs=${CORESURFACE_XML_SEARCH_DIRS:-$CS_XML_DEFAULT_DIRS}

  # Pass 1: exact runtime device XML match
  if [ -n "$_cs_dev" ]; then
    _cs_old_ifs=$IFS
    IFS=':'
    for _cs_dir in $_cs_dirs; do
      IFS=$_cs_old_ifs
      [ -n "$_cs_dir" ] || continue
      _cs_cand="${_cs_dir}/${_cs_dev}.xml"
      if cs_xml_is_valid_features_xml "$_cs_cand"; then
        CS_XML_DISCOVERED="$_cs_cand"
        return 0
      fi
    done
    IFS=$_cs_old_ifs
  fi

  # Pass 2: fallback to first valid .xml file in search directories
  _cs_old_ifs=$IFS
  IFS=':'
  for _cs_dir in $_cs_dirs; do
    IFS=$_cs_old_ifs
    if [ -z "$_cs_dir" ] || [ ! -d "$_cs_dir" ]; then
      continue
    fi
    for _cs_cand in "$_cs_dir"/*.xml; do
      [ -e "$_cs_cand" ] || break
      if cs_xml_is_valid_features_xml "$_cs_cand"; then
        CS_XML_DISCOVERED="$_cs_cand"
        return 0
      fi
    done
  done
  IFS=$_cs_old_ifs

  return 1
}

# Build desired <bool> and <integer> patch specifications based ONLY on verified
# active features (zero gimmick: Gallery Pro removed; Low tier excludes Advanced Textures;
# Custom Color Expert enabled across all tiers).
# Format per line: type|name|value
cs_xml_build_patch_spec() {
  _cs_spec_file=$1

  {
    if [ "$EFF_FEAT_BLUR" = "1" ]; then
      printf 'bool|support_background_blur|true\n'
      printf 'bool|support_realtime_blur|true\n'
      if [ "${EFF_FEAT_ADV_TEXTURES:-0}" = "1" ]; then
        printf 'bool|support_advanced_textures|true\n'
      fi
    fi

    if [ "$EFF_FEAT_ANIMATIONS" = "1" ]; then
      if [ "${CS_EFF_TIER:-low}" = "flagship" ]; then
        printf 'integer|device_level|3\n'
      else
        printf 'integer|device_level|2\n'
      fi
    fi

    if [ "$EFF_FEAT_MULTITASK" = "1" ]; then
      printf 'bool|support_multi_window|true\n'
      printf 'integer|freeform_max_count|4\n'
    fi

    if [ "$EFF_FEAT_COLOR_EXPERT" = "1" ]; then
      # Unlocks Advanced settings / Custom color menu across all modes without touching Vivid/Saturated/Standard
      printf 'bool|support_display_expert_mode|true\n'
    fi

    if [ "$EFF_FEAT_AOD_UNLOCK" = "1" ]; then
      printf 'bool|support_aod|true\n'
      printf 'bool|aod_support_keycode_goto_dismiss|true\n'
      # Critical non-LTPO AOD unlock (verified from HyperOS MiuiAod & HyperUnlocked):
      # Stock non-LTPO XML ships is_only_support_keycode_goto=true which hides "Always" & "Scheduled".
      # NOTE: Deliberately omit support_aod_aon and is_video_screen so non-LTPO optical-FOD panels
      # do not trigger AON/fullscreen Doze state transitions (which cause white flashes when the FOD ring fades out).
      printf 'bool|is_only_support_keycode_goto|false\n'
      # HyperOS 3 dynamic safety gate: avoid support_aod_fullscreen on HOS 3+
      if [ "${CS_HYPEROS_MAJOR:-0}" -lt 3 ]; then
        printf 'bool|support_aod_fullscreen|true\n'
      fi
    fi

    if [ "${EFF_FEAT_FLAGSHIP_AUDIO:-0}" = "1" ]; then
      # Flagship Audio & Speaker Suite (Dolby, Hi-Fi, Sound Assistant, Audio Share, 24-bit/Stereo/Studio Mic Record)
      printf 'bool|support_dolby|true\n'
      printf 'bool|support_hifi|true\n'
      printf 'bool|support_sound_assist|true\n'
      printf 'bool|support_audio_share|true\n'
      printf 'bool|support_stereo_record|true\n'
      printf 'bool|support_24bit_record|true\n'
      printf 'bool|support_lhdc_offload|true\n'
      printf 'bool|support_audio_loopback|true\n'
      printf 'bool|support_phone_call_noise_suppression|true\n'
      printf 'bool|support_interview_record_param|true\n'
      printf 'bool|support_hd_record_param|true\n'
    fi

    if [ "${EFF_FEAT_FLAGSHIP_SUITE:-0}" = "1" ]; then
      # Flagship Exclusive Porting Suite (AI Image Engine, Video Toolbox, Game Turbo Wild Boost,
      # Gallery HDR/Dolby/Local OCR, Privacy Cast, VoIP Record, Power Modes)
      # NOTE: Deliberately omit panel-specific HBM brighten flags (support_hdr_hbm_brighten /
      # support_manual_brightness_boost / support_dolby_version_brighten) to avoid FOD HBM white flashes on AOD.
      printf 'bool|support_AI_display|true\n'
      printf 'bool|support_super_resolution|true\n'
      printf 'bool|support_hdr_enhance|true\n'
      printf 'bool|support_screen_enhance_engine|true\n'
      printf 'bool|support_truetone|true\n'
      printf 'bool|is_support_video_tool_box|true\n'
      printf 'bool|support_videobox_display_effect|true\n'
      printf 'bool|support_videobox_cinema_adapt_ce|true\n'
      printf 'bool|support_displayfeature_gamemode|true\n'
      printf 'bool|support_displayfeature_gamemode_HDR|true\n'
      printf 'bool|support_touchfeature_gamemode|true\n'
      printf 'bool|support_game_mi_time|true\n'
      printf 'bool|support_wild_boost|true\n'
      printf 'bool|support_wild_boost_bat_perf|true\n'
      printf 'bool|support_mi_game_macro|true\n'
      printf 'bool|support_game_gunsight|true\n'
      printf 'bool|support_gallery_hdr|true\n'
      printf 'bool|gallery_support_dolby|true\n'
      printf 'bool|gallery_support_analytic_face_and_scene|true\n'
      printf 'bool|gallery_support_video_compress|true\n'
      printf 'bool|gallery_support_time_burst_video|true\n'
      printf 'bool|support_local_ocr|true\n'
      printf 'bool|support_miplay_cast_privacy|true\n'
      printf 'bool|support_voip_record|true\n'
      printf 'bool|support_conversation_toolbox_voiprecord|true\n'
      printf 'bool|support_new_silentmode|true\n'
      printf 'bool|support_dark_mode_notify|true\n'
      printf 'bool|support_autobrightness_optimize|true\n'
      printf 'bool|support_autobrightness_by_application_category|true\n'
      printf 'bool|support_app_hiding|true\n'
      printf 'bool|is_support_partial_screenshot|true\n'
      printf 'bool|support_ui_orientation_v2|true\n'
      printf 'bool|support_power_mode|true\n'
      printf 'bool|support_power_save_new|true\n'
      printf 'integer|support_inner_record|1\n'
    fi
  } > "$_cs_spec_file"
}

# Non-destructive XML patcher using POSIX awk:
# - Protected tags (fpsList, color/screen_effect, double_tap) are never modified.
# - Capability <bool>: only upgrades false -> true; never downgrades true -> false.
# - Whitelisted restriction-removal <bool> (is_only_support_keycode_goto): flips true -> false.
# - <integer>: only upgrades when desired > existing; never lowers an existing higher value.
# - Missing whitelisted tags are appended cleanly before </features>.
cs_xml_patch_file() {
  _cs_src=$1
  _cs_spec=$2
  _cs_dst=$3

  awk -F '|' '
    function is_protected(name) {
      if (name ~ /(fps|refresh|double_tap|screen_effect|color_mode|color_gamut|vivid|saturat|paper_mode|eyecare|sunlight)/) {
        return 1
      }
      return 0
    }
    function is_restriction_bool(name) {
      return (name == "is_only_support_keycode_goto")
    }
    NR == FNR {
      if (NF == 3 && !is_protected($2)) {
        n++
        order[n] = $2
        ptype[$2] = $1
        pval[$2] = $3
      }
      next
    }
    {
      line = $0
      if (line ~ /<\/features>/) {
        for (i = 1; i <= n; i++) {
          k = order[i]
          if (!seen[k]) {
            printf "    <%s name=\"%s\">%s</%s>\n", ptype[k], k, pval[k], ptype[k]
            seen[k] = 1
          }
        }
        print line
        next
      }

      matched = 0
      for (i = 1; i <= n; i++) {
        k = order[i]
        t = ptype[k]
        target = "<" t " name=\"" k "\">"
        close_tag = "</" t ">"
        pos = index(line, target)
        cpos = index(line, close_tag)
        if (pos > 0 && cpos > pos) {
          val_start = pos + length(target)
          cur = substr(line, val_start, cpos - val_start)
          gsub(/^[ \t]+|[ \t]+$/, "", cur)
          indent = ""
          if (match(line, /^[ \t]*/)) {
            indent = substr(line, 1, RLENGTH)
          }
          if (t == "bool") {
            # Add-only for capabilities (false -> true), plus explicit restriction removal (true -> false)
            if (cur == "false" && pval[k] == "true") {
              printf "%s<bool name=\"%s\">true</bool>\n", indent, k
            } else if (cur == "true" && pval[k] == "false" && is_restriction_bool(k)) {
              printf "%s<bool name=\"%s\">false</bool>\n", indent, k
            } else {
              print line
            }
          } else if (t == "integer") {
            # Non-destructive: never lower an existing higher integer
            if (cur ~ /^-?[0-9]+$/ && (cur + 0) >= (pval[k] + 0)) {
              print line
            } else {
              printf "%s<integer name=\"%s\">%s</integer>\n", indent, k, pval[k]
            }
          } else {
            print line
          }
          seen[k] = 1
          matched = 1
          break
        }
      }
      if (!matched) {
        print line
      }
    }
  ' "$_cs_spec" "$_cs_src" > "$_cs_dst"
}

cs_xml_restore_selinux_context() {
  _cs_ref=$1
  _cs_target=$2
  if command -v chcon >/dev/null 2>&1; then
    chcon --reference="$_cs_ref" "$_cs_target" 2>/dev/null \
      || chcon "u:object_r:system_file:s0" "$_cs_target" 2>/dev/null \
      || true
  fi
}

# Unmount any stale CoreSurface/soft-reboot bind-mount on a device_features XML.
# Must be called BEFORE reading the stock XML so soft-reboots never patch our own patched XML!
cs_xml_unmount_if_mounted() {
  _cs_um_target=${1:-}
  _cs_mounts=${CORESURFACE_PROC_MOUNTS:-/proc/mounts}
  [ -r "$_cs_mounts" ] || return 0

  if [ -n "$_cs_um_target" ]; then
    if awk -v target="$_cs_um_target" '$2 == target { found=1; exit } END { exit(found ? 0 : 1) }' "$_cs_mounts" 2>/dev/null; then
      umount -l "$_cs_um_target" 2>/dev/null || umount "$_cs_um_target" 2>/dev/null || true
    fi
    return 0
  fi

  # No target specified: unmount any mounted device_features/*.xml cleanly
  _cs_mounted_xmls=$(awk '$2 ~ /\/device_features\/.*\.xml$/ { print $2 }' "$_cs_mounts" 2>/dev/null || true)
  for _cs_mx in $_cs_mounted_xmls; do
    umount -l "$_cs_mx" 2>/dev/null || umount "$_cs_mx" 2>/dev/null || true
  done
}

# Run full fail-closed XML discovery, patching, validation, SELinux restore, and bind-mount.
# Always returns 0 so XML patch failures never disrupt boot.
cs_xml_apply() {
  cs_watchdog_init_dir || return 0
  : > "$CS_XML_PATCH_LIST"

  if [ "$EFF_FEAT_XML_PATCHER" != "1" ]; then
    cs_xml_unmount_if_mounted || true
    cs_state_set "XML_STATUS" "disabled"
    cs_state_set "XML_REASON" "disabled_by_config"
    cs_state_set "XML_SOURCE" "none"
    cs_state_set "XML_PATCHED_TAGS" "0"
    return 0
  fi

  if ! cs_xml_discover; then
    cs_state_set "XML_STATUS" "skipped"
    cs_state_set "XML_REASON" "source_xml_not_found"
    cs_state_set "XML_SOURCE" "none"
    cs_state_set "XML_PATCHED_TAGS" "0"
    cs_log "XML Patcher: no valid device_features XML discovered; skipping cleanly."
    return 0
  fi

  # On soft reboot, unmount any stale bind-mount BEFORE reading the source XML
  # so we always patch the true factory XML rather than a previous boot's output.
  cs_xml_unmount_if_mounted "$CS_XML_DISCOVERED"

  mkdir -p "$CS_XML_WORK_DIR" 2>/dev/null || {
    cs_state_set "XML_STATUS" "skipped"
    cs_state_set "XML_REASON" "work_dir_error"
    cs_state_set "XML_SOURCE" "$CS_XML_DISCOVERED"
    cs_state_set "XML_PATCHED_TAGS" "0"
    cs_log "XML Patcher: cannot create work directory; skipping cleanly."
    return 0
  }

  _cs_spec="$CS_XML_WORK_DIR/patch_spec.tmp.$$"
  _cs_tmp_xml="$CS_XML_WORK_FILE.tmp.$$"
  cs_xml_build_patch_spec "$_cs_spec"

  _cs_tag_count=$(wc -l < "$_cs_spec" 2>/dev/null | tr -d ' \t\r\n')
  if [ "${_cs_tag_count:-0}" -eq 0 ]; then
    rm -f "$_cs_spec"
    cs_state_set "XML_STATUS" "skipped"
    cs_state_set "XML_REASON" "no_active_xml_features"
    cs_state_set "XML_SOURCE" "$CS_XML_DISCOVERED"
    cs_state_set "XML_PATCHED_TAGS" "0"
    cs_log "XML Patcher: 0 active feature tags to patch; skipping bind-mount."
    return 0
  fi

  if ! cs_xml_patch_file "$CS_XML_DISCOVERED" "$_cs_spec" "$_cs_tmp_xml"; then
    rm -f "$_cs_spec" "$_cs_tmp_xml"
    cs_state_set "XML_STATUS" "skipped"
    cs_state_set "XML_REASON" "patch_command_failed"
    cs_state_set "XML_SOURCE" "$CS_XML_DISCOVERED"
    cs_state_set "XML_PATCHED_TAGS" "0"
    cs_log "XML Patcher: awk patching failed; fail-closed skip."
    return 0
  fi

  # Fail-closed XML structural & non-truncation check before bind-mount
  _cs_src_lines=$(wc -l < "$CS_XML_DISCOVERED" 2>/dev/null | tr -d ' \t\r\n')
  _cs_dst_lines=$(wc -l < "$_cs_tmp_xml" 2>/dev/null | tr -d ' \t\r\n')
  if ! cs_xml_is_valid_features_xml "$_cs_tmp_xml" || [ "${_cs_dst_lines:-0}" -lt "${_cs_src_lines:-1}" ]; then
    rm -f "$_cs_spec" "$_cs_tmp_xml"
    cs_state_set "XML_STATUS" "skipped"
    cs_state_set "XML_REASON" "xml_validation_failed"
    cs_state_set "XML_SOURCE" "$CS_XML_DISCOVERED"
    cs_state_set "XML_PATCHED_TAGS" "0"
    cs_log "XML Patcher: patched XML failed structural/line-count validation; fail-closed skip."
    return 0
  fi

  mv -f "$_cs_tmp_xml" "$CS_XML_WORK_FILE"
  chmod 0644 "$CS_XML_WORK_FILE" 2>/dev/null || true
  chown 0:0 "$CS_XML_WORK_FILE" 2>/dev/null || true
  cs_xml_restore_selinux_context "$CS_XML_DISCOVERED" "$CS_XML_WORK_FILE"
  cp "$_cs_spec" "$CS_XML_PATCH_LIST" 2>/dev/null || true
  rm -f "$_cs_spec"

  # Perform bind-mount onto original path
  if mount --bind "$CS_XML_WORK_FILE" "$CS_XML_DISCOVERED" 2>/dev/null; then
    cs_state_set "XML_STATUS" "mounted"
    cs_state_set "XML_REASON" "bind_mount_ok"
    cs_state_set "XML_SOURCE" "$CS_XML_DISCOVERED"
    cs_state_set "XML_PATCHED_TAGS" "$_cs_tag_count"
    cs_log "XML Patcher: patched ${_cs_tag_count} tags and bind-mounted ${CS_XML_DISCOVERED}."
  else
    cs_state_set "XML_STATUS" "skipped"
    cs_state_set "XML_REASON" "bind_mount_failed"
    cs_state_set "XML_SOURCE" "$CS_XML_DISCOVERED"
    cs_state_set "XML_PATCHED_TAGS" "0"
    cs_log "XML Patcher: mount --bind failed for ${CS_XML_DISCOVERED}; fail-closed skip."
  fi

  return 0
}
