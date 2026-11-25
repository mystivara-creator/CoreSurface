#!/system/bin/sh
# CoreSurface - Shared LSPosed Engine APK Lifecycle Manager (Pure POSIX sh)
# Handles SELinux-safe pm install (-S stream + /data/local/tmp + su 2000 fallback),
# signature-mismatch recovery, idempotent install stamps, and clean uninstall.

CS_ENGINE_PKG="org.mystivara.coresurface.engine"

cs_pm_is_installed() {
  command -v pm >/dev/null 2>&1 || return 1
  _cs_pmi_out=$(pm path "$CS_ENGINE_PKG" 2>&1 || true)
  case "$_cs_pmi_out" in
    package:*) return 0 ;;
  esac
  if command -v su >/dev/null 2>&1; then
    _cs_pmi_out=$(su 2000 -c "pm path '${CS_ENGINE_PKG}'" 2>&1 || true)
    case "$_cs_pmi_out" in
      package:*) return 0 ;;
    esac
  fi
  return 1
}

cs_pm_uninstall_engine() {
  command -v pm >/dev/null 2>&1 || return 0
  pm uninstall "$CS_ENGINE_PKG" >/dev/null 2>&1 || true
  if command -v su >/dev/null 2>&1; then
    su 2000 -c "pm uninstall '${CS_ENGINE_PKG}'" >/dev/null 2>&1 || true
  fi
  return 0
}

cs_pm_try_install_once() {
  _cs_pi_apk=$1
  _cs_pi_size=$(wc -c < "$_cs_pi_apk" 2>/dev/null | tr -d ' \t\r\n')
  CS_PM_LAST_OUT=""

  if [ -n "$_cs_pi_size" ] && [ "$_cs_pi_size" -gt 0 ] 2>/dev/null; then
    CS_PM_LAST_OUT=$(pm install -r -S "$_cs_pi_size" < "$_cs_pi_apk" 2>&1 || true)
    case "$CS_PM_LAST_OUT" in
      *Success*) return 0 ;;
      *INSTALL_FAILED_UPDATE_INCOMPATIBLE*) return 2 ;;
    esac
  fi

  # SELinux-safe fallback: stage in /data/local/tmp (readable by installd & UID 2000)
  _cs_pi_tmp="/data/local/tmp/coresurface_engine_install.apk"
  if cp "$_cs_pi_apk" "$_cs_pi_tmp" 2>/dev/null; then
    chmod 0644 "$_cs_pi_tmp" 2>/dev/null || true
    CS_PM_LAST_OUT=$(pm install -r "$_cs_pi_tmp" 2>&1 || true)
    case "$CS_PM_LAST_OUT" in
      *Success*)
        rm -f "$_cs_pi_tmp" 2>/dev/null || true
        return 0
        ;;
      *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
        rm -f "$_cs_pi_tmp" 2>/dev/null || true
        return 2
        ;;
    esac
    if command -v su >/dev/null 2>&1; then
      CS_PM_LAST_OUT=$(su 2000 -c "pm install -r '${_cs_pi_tmp}'" 2>&1 || true)
      case "$CS_PM_LAST_OUT" in
        *Success*)
          rm -f "$_cs_pi_tmp" 2>/dev/null || true
          return 0
          ;;
        *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
          rm -f "$_cs_pi_tmp" 2>/dev/null || true
          return 2
          ;;
      esac
    fi
    rm -f "$_cs_pi_tmp" 2>/dev/null || true
  fi

  return 1
}

cs_pm_install_apk() {
  _cs_pi_target=$1
  [ -r "$_cs_pi_target" ] || return 1
  command -v pm >/dev/null 2>&1 || return 1

  cs_pm_try_install_once "$_cs_pi_target"
  _cs_pi_rc=$?
  if [ "$_cs_pi_rc" -eq 0 ]; then
    return 0
  fi
  if [ "$_cs_pi_rc" -eq 2 ]; then
    cs_pm_uninstall_engine
    cs_log "Engine Installer: replaced previous signature build of CoreSurfaceEngine.apk."
    cs_pm_try_install_once "$_cs_pi_target"
    return $?
  fi

  return 1
}

cs_engine_apk_sig() {
  _cs_es_apk=$1
  [ -r "$_cs_es_apk" ] || return 0
  cksum "$_cs_es_apk" 2>/dev/null | awk '{print $1 "-" $2}' || true
}

cs_engine_write_stamp() {
  _cs_ews_apk=$1
  _cs_ews_sig=$(cs_engine_apk_sig "$_cs_ews_apk")
  if [ -n "$_cs_ews_sig" ]; then
    printf '%s\n' "$_cs_ews_sig" > "$CS_STATE_DIR/.engine_installed.sig" 2>/dev/null || true
  fi
}

cs_install_engine_if_needed() {
  _cs_ie_moddir=${1:-${MODDIR:-}}
  _cs_apk="$CS_STATE_DIR/CoreSurfaceEngine.apk"
  [ -r "$_cs_apk" ] || _cs_apk="${_cs_ie_moddir}/engine/CoreSurfaceEngine.apk"
  [ -r "$_cs_apk" ] || return 0
  command -v pm >/dev/null 2>&1 || return 0

  _cs_stamp="$CS_STATE_DIR/.engine_installed.sig"
  _cs_cur_sig=$(cs_engine_apk_sig "$_cs_apk")
  _cs_prev_sig=""
  [ -r "$_cs_stamp" ] && _cs_prev_sig=$(cat "$_cs_stamp" 2>/dev/null || true)

  if [ -n "$_cs_cur_sig" ] && [ "$_cs_cur_sig" = "$_cs_prev_sig" ] && cs_pm_is_installed; then
    return 0
  fi

  if cs_pm_install_apk "$_cs_apk"; then
    cs_engine_write_stamp "$_cs_apk"
    cs_log "Engine Installer: installed/updated CoreSurfaceEngine.apk (enable in LSPosed)."
  else
    cs_log "Engine Installer: automatic pm install skipped (install manually from ${_cs_apk})."
  fi
  return 0
}
