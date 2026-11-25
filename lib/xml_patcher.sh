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
      printf 'bool|support_aod_aon|true\n'
      printf 'bool|aod_support_keycode_goto_dismiss|true\n'
      # HyperOS 3 dynamic safety gate: avoid support_aod_fullscreen on HOS 3+
      if [ "${CS_HYPEROS_MAJOR:-0}" -lt 3 ]; then
        printf 'bool|support_aod_fullscreen|true\n'
      fi
    fi
  } > "$_cs_spec_file"
}

# Non-destructive / Add-Only XML patcher using POSIX awk:
# - Protected tags (fpsList, color/screen_effect, double_tap) are never modified.
# - <bool>: only upgrades false -> true; never downgrades true -> false.
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
          indent = ""
          if (match(line, /^[ \t]*/)) {
            indent = substr(line, 1, RLENGTH)
          }
          if (t == "bool") {
            # Add-only: only change false -> true
            if (cur == "false" && pval[k] == "true") {
              printf "%s<bool name=\"%s\">true</bool>\n", indent, k
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

# Run full fail-closed XML discovery, patching, validation, SELinux restore, and bind-mount.
# Always returns 0 so XML patch failures never disrupt boot.
cs_xml_apply() {
  cs_watchdog_init_dir || return 0
  : > "$CS_XML_PATCH_LIST"

  if [ "$EFF_FEAT_XML_PATCHER" != "1" ]; then
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

  # Fail-closed XML structural check before bind-mount
  if ! cs_xml_is_valid_features_xml "$_cs_tmp_xml"; then
    rm -f "$_cs_spec" "$_cs_tmp_xml"
    cs_state_set "XML_STATUS" "skipped"
    cs_state_set "XML_REASON" "xml_validation_failed"
    cs_state_set "XML_SOURCE" "$CS_XML_DISCOVERED"
    cs_state_set "XML_PATCHED_TAGS" "0"
    cs_log "XML Patcher: patched XML failed validation (empty or missing </features>); fail-closed skip."
    return 0
  fi

  mv -f "$_cs_tmp_xml" "$CS_XML_WORK_FILE"
  chmod 0644 "$CS_XML_WORK_FILE" 2>/dev/null || true
  chown 0:0 "$CS_XML_WORK_FILE" 2>/dev/null || true
  cs_xml_restore_selinux_context "$CS_XML_DISCOVERED" "$CS_XML_WORK_FILE"
  cp "$_cs_spec" "$CS_XML_PATCH_LIST" 2>/dev/null || true
  rm -f "$_cs_spec"

  # On soft reboot, the target XML may already be bind-mounted; unmount cleanly first
  _cs_mounts=${CORESURFACE_PROC_MOUNTS:-/proc/mounts}
  if [ -r "$_cs_mounts" ] && awk -v target="$CS_XML_DISCOVERED" '$2 == target { found=1; exit } END { exit(found ? 0 : 1) }' "$_cs_mounts" 2>/dev/null; then
    umount -l "$CS_XML_DISCOVERED" 2>/dev/null || umount "$CS_XML_DISCOVERED" 2>/dev/null || true
  fi

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
