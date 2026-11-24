#!/system/bin/sh
# CoreSurface - Dynamic Clean-Room RRO Overlay & Video Depth Staging Manager
# Pure POSIX sh. Stages compiled RRO APKs and Lockscreen Video Depth marker
# under $MODDIR/system/product/ based on active features and clears them fail-closed.

CS_RRO_STAGED_LIST="$CS_STATE_DIR/rro_staged.list"
CS_VIDEO_DEPTH_REL="system/product/media/wallpaper/sysui_editor_wallpaper_group/enable_video_depth"

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

cs_rro_stage_one() {
  _cs_rs_src_dir=$1
  _cs_rs_dst_dir=$2
  _cs_rs_apk=$3
  _cs_rs_pkg=$4

  [ -r "$_cs_rs_src_dir/$_cs_rs_apk" ] || return 0
  cp "$_cs_rs_src_dir/$_cs_rs_apk" "$_cs_rs_dst_dir/$_cs_rs_apk" || return 1
  chmod 0644 "$_cs_rs_dst_dir/$_cs_rs_apk" 2>/dev/null || true
  printf '%s|%s\n' "$_cs_rs_apk" "$_cs_rs_pkg" >> "$CS_RRO_STAGED_LIST"
  CS_RRO_COUNT=$((CS_RRO_COUNT + 1))
  return 0
}

# Stage RRO APKs and Lockscreen Video Depth marker according to resolved EFF_FEAT_* flags.
# Called during customize.sh, webui_ctl.sh config updates, and post-fs-data.sh guardrails.
cs_rro_stage() {
  _cs_rs_moddir=$1
  _cs_rs_src="$_cs_rs_moddir/overlays"
  _cs_rs_dst="$_cs_rs_moddir/system/product/overlay"

  cs_watchdog_init_dir || return 0
  cs_rro_clear "$_cs_rs_moddir"

  CS_RRO_COUNT=0

  # 1. Clean-Room RRO APKs
  if [ "$EFF_FEAT_RRO_OVERLAYS" = "1" ]; then
    if [ -d "$_cs_rs_src" ] && mkdir -p "$_cs_rs_dst" 2>/dev/null; then
      chmod 0755 "$_cs_rs_moddir/system" "$_cs_rs_moddir/system/product" "$_cs_rs_dst" 2>/dev/null || true

      if [ "$EFF_FEAT_ANIMATIONS" = "1" ] || [ "$EFF_FEAT_BLUR" = "1" ]; then
        cs_rro_stage_one "$_cs_rs_src" "$_cs_rs_dst" \
          "CoreSurfaceSystemUI.apk" "org.mystivara.coresurface.overlay.systemui" || true
      fi

      if [ "$EFF_FEAT_BLUR" != "1" ]; then
        cs_rro_stage_one "$_cs_rs_src" "$_cs_rs_dst" \
          "CoreSurfaceSystemUILiteBlur.apk" "org.mystivara.coresurface.overlay.systemui.liteblur" || true
      fi

      cs_rro_stage_one "$_cs_rs_src" "$_cs_rs_dst" \
        "CoreSurfaceThemeManager.apk" "org.mystivara.coresurface.overlay.thememanager" || true
      cs_rro_stage_one "$_cs_rs_src" "$_cs_rs_dst" \
        "CoreSurfaceMiWallpaper.apk" "org.mystivara.coresurface.overlay.miwallpaper" || true

      cs_state_set "RRO_STAGED_COUNT" "$CS_RRO_COUNT"
      if [ "$CS_RRO_COUNT" -gt 0 ]; then
        cs_state_set "RRO_STATUS" "staged"
        cs_log "RRO Manager: staged ${CS_RRO_COUNT} clean-room overlays into ${_cs_rs_dst}."
      else
        rmdir "$_cs_rs_dst" 2>/dev/null || true
        cs_state_set "RRO_STATUS" "skipped"
      fi
    else
      cs_state_set "RRO_STATUS" "skipped"
    fi
  else
    cs_state_set "RRO_STATUS" "disabled"
  fi

  # 2. Lockscreen Video Depth zero-byte marker
  if [ "$EFF_FEAT_VIDEO_DEPTH" = "1" ]; then
    _cs_vd_dir="$_cs_rs_moddir/system/product/media/wallpaper/sysui_editor_wallpaper_group"
    if mkdir -p "$_cs_vd_dir" 2>/dev/null && : > "$_cs_vd_dir/enable_video_depth"; then
      chmod 0644 "$_cs_vd_dir/enable_video_depth" 2>/dev/null || true
      cs_state_set "VIDEO_DEPTH_STATUS" "staged"
    else
      cs_state_set "VIDEO_DEPTH_STATUS" "skipped"
    fi
  else
    cs_state_set "VIDEO_DEPTH_STATUS" "disabled"
  fi

  return 0
}
