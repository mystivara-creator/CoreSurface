#!/system/bin/sh
# CoreSurface - Dynamic Clean-Room RRO Overlay & Video Depth Staging Manager
# Pure POSIX sh. Idempotent staging with SELinux u:object_r:system_file:s0 labeling
# so PackageManager / OverlayManagerService can load RRO APKs under SELinux Enforcing.

CS_RRO_STAGED_LIST="$CS_STATE_DIR/rro_staged.list"
CS_VIDEO_DEPTH_REL="system/product/media/wallpaper/sysui_editor_wallpaper_group/enable_video_depth"

cs_rro_fix_labels() {
  _cs_rl_moddir=$1
  [ -d "$_cs_rl_moddir/system" ] || return 0
  chown -R 0:0 "$_cs_rl_moddir/system" 2>/dev/null || true
  find "$_cs_rl_moddir/system" -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$_cs_rl_moddir/system" -type f -exec chmod 0644 {} + 2>/dev/null || true
  if command -v chcon >/dev/null 2>&1; then
    chcon -R u:object_r:system_file:s0 "$_cs_rl_moddir/system" 2>/dev/null || true
  fi
}

cs_rro_clear() {
  _cs_rc_moddir=$1
  _cs_rc_dst="$_cs_rc_moddir/system/product/overlay"
  _cs_rc_vd="$_cs_rc_moddir/$CS_VIDEO_DEPTH_REL"

  if [ -d "$_cs_rc_dst" ]; then
    rm -f "$_cs_rc_dst"/CoreSurface*.apk 2>/dev/null || true
    rmdir "$_cs_rc_dst" 2>/dev/null || true
  fi

  if [ -e "$_cs_rc_vd" ]; then
    rm -f "$_cs_rc_vd" 2>/dev/null || true
    rmdir "$_cs_rc_moddir/system/product/media/wallpaper/sysui_editor_wallpaper_group" 2>/dev/null || true
    rmdir "$_cs_rc_moddir/system/product/media/wallpaper" 2>/dev/null || true
    rmdir "$_cs_rc_moddir/system/product/media" 2>/dev/null || true
  fi

  rmdir "$_cs_rc_moddir/system/product" 2>/dev/null || true
  rmdir "$_cs_rc_moddir/system" 2>/dev/null || true

  cs_watchdog_init_dir || return 0
  : > "$CS_RRO_STAGED_LIST"
  cs_state_set "RRO_STAGED_COUNT" "0"
  cs_state_set "VIDEO_DEPTH_STATUS" "disabled"
  return 0
}

cs_rro_sync_one() {
  _cs_rs_src_dir=$1
  _cs_rs_dst_dir=$2
  _cs_rs_apk=$3
  _cs_rs_pkg=$4

  [ -r "$_cs_rs_src_dir/$_cs_rs_apk" ] || return 0
  # Idempotent: only copy if missing or content differs (preserves idmap2 cache)
  if [ ! -f "$_cs_rs_dst_dir/$_cs_rs_apk" ] || ! cmp -s "$_cs_rs_src_dir/$_cs_rs_apk" "$_cs_rs_dst_dir/$_cs_rs_apk"; then
    cp "$_cs_rs_src_dir/$_cs_rs_apk" "$_cs_rs_dst_dir/$_cs_rs_apk" || return 1
  fi
  printf '%s|%s\n' "$_cs_rs_apk" "$_cs_rs_pkg" >> "$CS_RRO_STAGED_LIST"
  CS_RRO_COUNT=$((CS_RRO_COUNT + 1))
  return 0
}

cs_rro_remove_unwanted() {
  _cs_ru_dst_dir=$1
  [ -d "$_cs_ru_dst_dir" ] || return 0
  for _cs_existing in "$_cs_ru_dst_dir"/CoreSurface*.apk; do
    [ -e "$_cs_existing" ] || break
    _cs_base=$(basename "$_cs_existing")
    if ! grep -F -q "${_cs_base}|" "$CS_RRO_STAGED_LIST" 2>/dev/null; then
      rm -f "$_cs_existing" 2>/dev/null || true
    fi
  done
}

# Stage RRO APKs and Lockscreen Video Depth marker idempotently with proper SELinux labels.
cs_rro_stage() {
  _cs_rs_moddir=$1
  _cs_rs_src="$_cs_rs_moddir/overlays"
  _cs_rs_dst="$_cs_rs_moddir/system/product/overlay"

  cs_watchdog_init_dir || return 0
  : > "$CS_RRO_STAGED_LIST"
  CS_RRO_COUNT=0

  # 1. Clean-Room RRO APKs
  if [ "$EFF_FEAT_RRO_OVERLAYS" = "1" ]; then
    if [ -d "$_cs_rs_src" ] && mkdir -p "$_cs_rs_dst" 2>/dev/null; then
      if [ "$EFF_FEAT_ANIMATIONS" = "1" ] || [ "$EFF_FEAT_BLUR" = "1" ]; then
        cs_rro_sync_one "$_cs_rs_src" "$_cs_rs_dst" \
          "CoreSurfaceSystemUI.apk" "org.mystivara.coresurface.overlay.systemui" || true
      fi

      if [ "$EFF_FEAT_BLUR" != "1" ]; then
        cs_rro_sync_one "$_cs_rs_src" "$_cs_rs_dst" \
          "CoreSurfaceSystemUILiteBlur.apk" "org.mystivara.coresurface.overlay.systemui.liteblur" || true
      fi

      cs_rro_sync_one "$_cs_rs_src" "$_cs_rs_dst" \
        "CoreSurfaceThemeManager.apk" "org.mystivara.coresurface.overlay.thememanager" || true

      if [ "${CS_EFF_TIER:-low}" != "low" ]; then
        cs_rro_sync_one "$_cs_rs_src" "$_cs_rs_dst" \
          "CoreSurfaceMiWallpaper.apk" "org.mystivara.coresurface.overlay.miwallpaper" || true
      fi

      if [ "$EFF_FEAT_AOD_UNLOCK" = "1" ]; then
        cs_rro_sync_one "$_cs_rs_src" "$_cs_rs_dst" \
          "CoreSurfaceMiuiAod.apk" "org.mystivara.coresurface.overlay.miuiaod" || true
      fi

      cs_rro_remove_unwanted "$_cs_rs_dst"
      cs_state_set "RRO_STAGED_COUNT" "$CS_RRO_COUNT"
      if [ "$CS_RRO_COUNT" -gt 0 ]; then
        cs_state_set "RRO_STATUS" "staged"
        cs_log "RRO Manager: synced ${CS_RRO_COUNT} clean-room overlays (SELinux system_file)."
      else
        rmdir "$_cs_rs_dst" 2>/dev/null || true
        cs_state_set "RRO_STATUS" "skipped"
      fi
    else
      cs_state_set "RRO_STATUS" "skipped"
    fi
  else
    if [ -d "$_cs_rs_dst" ]; then
      rm -f "$_cs_rs_dst"/CoreSurface*.apk 2>/dev/null || true
      rmdir "$_cs_rs_dst" 2>/dev/null || true
    fi
    cs_state_set "RRO_STAGED_COUNT" "0"
    cs_state_set "RRO_STATUS" "disabled"
  fi

  # 2. Lockscreen Video Depth zero-byte marker
  _cs_vd_dir="$_cs_rs_moddir/system/product/media/wallpaper/sysui_editor_wallpaper_group"
  if [ "$EFF_FEAT_VIDEO_DEPTH" = "1" ]; then
    if mkdir -p "$_cs_vd_dir" 2>/dev/null; then
      [ -f "$_cs_vd_dir/enable_video_depth" ] || : > "$_cs_vd_dir/enable_video_depth"
      cs_state_set "VIDEO_DEPTH_STATUS" "staged"
    else
      cs_state_set "VIDEO_DEPTH_STATUS" "skipped"
    fi
  else
    if [ -e "$_cs_vd_dir/enable_video_depth" ]; then
      rm -f "$_cs_vd_dir/enable_video_depth" 2>/dev/null || true
      rmdir "$_cs_vd_dir" 2>/dev/null || true
      rmdir "$_cs_rs_moddir/system/product/media/wallpaper" 2>/dev/null || true
      rmdir "$_cs_rs_moddir/system/product/media" 2>/dev/null || true
    fi
    cs_state_set "VIDEO_DEPTH_STATUS" "disabled"
  fi

  # Clean up empty parent directories if nothing is staged
  rmdir "$_cs_rs_moddir/system/product" 2>/dev/null || true
  rmdir "$_cs_rs_moddir/system" 2>/dev/null || true

  # Always restore ownership, permissions, and SELinux system_file context
  cs_rro_fix_labels "$_cs_rs_moddir"
  return 0
}

# Post-boot RRO activator: enables any staged CoreSurface overlay that OverlayManagerService
# registered as disabled (`[ ] <pkg>`) so all mounted overlays become active (`[x]`).
cs_rro_enable_staged() {
  CS_RRO_OV_LIST_CACHE=""
  export CS_RRO_OV_LIST_CACHE
  [ "${EFF_FEAT_RRO_OVERLAYS:-0}" = "1" ] || return 0
  [ -s "$CS_RRO_STAGED_LIST" ] || return 0
  command -v cmd >/dev/null 2>&1 || return 0

  _cs_ov_list=$(cmd overlay list --user 0 2>&1 || true)
  case "$_cs_ov_list" in
    ""|*Failure*|*Exception*|*Error*|*Binder*)
      if command -v su >/dev/null 2>&1; then
        _cs_ov_list=$(su 2000 -c "cmd overlay list --user 0" 2>&1 || true)
      fi
      ;;
  esac
  case "$_cs_ov_list" in
    ""|*Failure*|*Exception*|*Error*|*Binder*)
      if command -v su >/dev/null 2>&1; then
        _cs_ov_list=$(su --context u:r:shell:s0 2000 -c "cmd overlay list --user 0" 2>&1 || true)
      fi
      ;;
  esac
  case "$_cs_ov_list" in
    ""|*Failure*|*Exception*|*Error*|*Binder*)
      for _cs_rbb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
        if [ -x "$_cs_rbb" ]; then
          _cs_ov_list=$("$_cs_rbb" setuidgid 2000 cmd overlay list --user 0 2>&1 || true)
          break
        fi
      done
      ;;
  esac
  [ -n "$_cs_ov_list" ] || return 0

  _cs_en_count=0
  while IFS='|' read -r _cs_eapk _cs_epkg || [ -n "$_cs_eapk" ]; do
    [ -n "$_cs_epkg" ] || continue
    if printf '%s\n' "$_cs_ov_list" | grep -F -q "[ ] $_cs_epkg"; then
      if cmd overlay enable --user 0 "$_cs_epkg" >/dev/null 2>&1; then
        _cs_en_count=$((_cs_en_count + 1))
      elif command -v su >/dev/null 2>&1 && su 2000 -c "cmd overlay enable --user 0 '${_cs_epkg}'" >/dev/null 2>&1; then
        _cs_en_count=$((_cs_en_count + 1))
      elif command -v su >/dev/null 2>&1 && su --context u:r:shell:s0 2000 -c "cmd overlay enable --user 0 '${_cs_epkg}'" >/dev/null 2>&1; then
        _cs_en_count=$((_cs_en_count + 1))
      else
        for _cs_rbb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
          if [ -x "$_cs_rbb" ] && "$_cs_rbb" setuidgid 2000 cmd overlay enable --user 0 "$_cs_epkg" >/dev/null 2>&1; then
            _cs_en_count=$((_cs_en_count + 1))
            break
          fi
        done
      fi
    fi
  done < "$CS_RRO_STAGED_LIST"

  if [ "$_cs_en_count" -gt 0 ]; then
    cs_log "RRO Manager: enabled ${_cs_en_count} registered overlay(s) via OverlayManagerService."
  else
    CS_RRO_OV_LIST_CACHE="$_cs_ov_list"
    export CS_RRO_OV_LIST_CACHE
  fi
  return 0
}
