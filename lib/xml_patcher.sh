#!/system/bin/sh
# CoreSurface - Dynamic device_features XML Patcher (Fail-Closed Bind-Mount)
# Pure POSIX sh + awk. Zero hardcoded device codenames.

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

# Build desired <bool> and <integer> patch specifications based on active features.
# Format per line: type|name|value
cs_xml_build_patch_spec() {
  _cs_spec_file=$1

  {
    if [ "$EFF_FEAT_BLUR" = "1" ]; then
      printf 'bool|support_background_blur|true\n'
      printf 'bool|support_advanced_textures|true\n'
      printf 'bool|support_realtime_blur|true\n'
    fi

    if [ "$EFF_FEAT_ANIMATIONS" = "1" ]; then
      if [ "$CS_RAM_TIER" = "high" ]; then
        printf 'integer|device_level|3\n'
      else
        printf 'integer|device_level|2\n'
      fi
      printf 'bool|support_papermode_animation|true\n'
    fi

    if [ "$EFF_FEAT_MULTITASK" = "1" ]; then
      printf 'bool|support_multi_window|true\n'
      printf 'integer|freeform_max_count|4\n'
    fi

    if [ "$EFF_FEAT_DISPLAY_HZ" = "1" ]; then
      printf 'bool|support_smart_fps|true\n'
      printf 'bool|support_high_refresh_rate|true\n'
    fi

    if [ "$EFF_FEAT_HYPERAI" = "1" ]; then
      printf 'bool|support_AI_display|true\n'
      printf 'bool|gallery_support_analytic_face_and_scene|true\n'
      printf 'bool|gallery_support_media_feature|true\n'
    fi

    if [ "$EFF_FEAT_AOD_UNLOCK" = "1" ]; then
      printf 'bool|support_aod|true\n'
      printf 'bool|support_aod_aon|true\n'
      # HyperOS 3 dynamic safety gate: avoid support_aod_fullscreen on HOS 3+
      if [ "${CS_HYPEROS_MAJOR:-0}" -lt 3 ]; then
        printf 'bool|support_aod_fullscreen|true\n'
      fi
    fi
  } > "$_cs_spec_file"
}

# Patch <bool name="..."> and <integer name="..."> tags cleanly using POSIX awk.
cs_xml_patch_file() {
  _cs_src=$1
  _cs_spec=$2
  _cs_dst=$3

  awk -F '|' '
    NR == FNR {
      if (NF == 3) {
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
        if (index(line, target) > 0 && index(line, "</" t ">") > 0) {
          indent = ""
          if (match(line, /^[ \t]*/)) {
            indent = substr(line, 1, RLENGTH)
          }
          printf "%s<%s name=\"%s\">%s</%s>\n", indent, t, k, pval[k], t
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

# Run full fail-closed XML discovery, patching, validation, and bind-mount.
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
