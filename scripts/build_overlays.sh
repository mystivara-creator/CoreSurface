#!/bin/sh
# CoreSurface v1.0.0 - Clean-Room RRO Overlay APK Builder (POSIX sh)
# Compiles XML sources in overlays-src/ into signed RRO APKs in build/overlays/.
# Supports Android SDK aapt2 (GitHub Actions ubuntu-latest) and system aapt (local Linux).

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SRC_DIR="$REPO_ROOT/overlays-src"
OUT_DIR=${CORESURFACE_OVERLAY_OUT:-"$REPO_ROOT/build/overlays"}
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

find_framework_jar() {
  for _sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" /usr/local/lib/android/sdk /usr/lib/android-sdk; do
    if [ -z "$_sdk" ] || [ ! -d "$_sdk/platforms" ]; then
      continue
    fi
    _jar=$(find "$_sdk/platforms" -maxdepth 2 -name android.jar 2>/dev/null | sort | tail -n 1 || true)
    if [ -n "$_jar" ] && [ -r "$_jar" ]; then
      printf '%s\n' "$_jar"
      return 0
    fi
  done

  if [ -r /usr/share/android-framework-res/framework-res.apk ]; then
    printf '/usr/share/android-framework-res/framework-res.apk\n'
    return 0
  fi

  return 1
}

find_sdk_tool() {
  _tool=$1
  for _sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" /usr/local/lib/android/sdk /usr/lib/android-sdk; do
    if [ -z "$_sdk" ] || [ ! -d "$_sdk/build-tools" ]; then
      continue
    fi
    _bin=$(find "$_sdk/build-tools" -maxdepth 2 -name "$_tool" -type f 2>/dev/null | sort | tail -n 1 || true)
    if [ -n "$_bin" ] && [ -x "$_bin" ]; then
      printf '%s\n' "$_bin"
      return 0
    fi
  done

  if command -v "$_tool" >/dev/null 2>&1; then
    command -v "$_tool"
    return 0
  fi

  return 1
}

FRAMEWORK_RES=$(find_framework_jar) || {
  printf 'ERROR: Cannot find android.jar or framework-res.apk\n' >&2
  exit 1
}

AAPT2_BIN=$(find_sdk_tool aapt2 || true)
AAPT_BIN=$(find_sdk_tool aapt || true)
APKSIGNER_BIN=$(find_sdk_tool apksigner || true)
ZIPALIGN_BIN=$(find_sdk_tool zipalign || true)

if [ -z "$AAPT2_BIN" ] && [ -z "$AAPT_BIN" ]; then
  printf 'ERROR: Neither aapt2 nor aapt found in PATH or ANDROID_HOME\n' >&2
  exit 1
fi

if [ -z "$APKSIGNER_BIN" ]; then
  printf 'ERROR: apksigner not found in PATH or ANDROID_HOME\n' >&2
  exit 1
fi

# Generate an ephemeral signing keystore for reproducible clean-room RRO signing
KEYSTORE="$WORK_DIR/coresurface-rro.jks"
keytool -genkeypair \
  -v \
  -keystore "$KEYSTORE" \
  -alias coresurface \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -storepass coresurface \
  -keypass coresurface \
  -dname "CN=CoreSurface, OU=CleanRoomRRO, O=Mystivara, L=Unknown, S=Unknown, C=ID" >/dev/null 2>&1

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/CoreSurface*.apk

build_one_overlay() {
  _src_name=$1
  _apk_name=$2
  _src="$SRC_DIR/$_src_name"
  _unsigned="$WORK_DIR/${_apk_name}.unsigned.apk"
  _aligned="$WORK_DIR/${_apk_name}.aligned.apk"
  _final="$OUT_DIR/${_apk_name}"

  if [ ! -f "$_src/AndroidManifest.xml" ]; then
    printf 'ERROR: Missing manifest in %s\n' "$_src" >&2
    exit 1
  fi

  if [ -n "$AAPT2_BIN" ]; then
    _flat="$WORK_DIR/${_src_name}.flata"
    "$AAPT2_BIN" compile --dir "$_src/res" -o "$_flat"
    "$AAPT2_BIN" link \
      -I "$FRAMEWORK_RES" \
      --manifest "$_src/AndroidManifest.xml" \
      -o "$_unsigned" \
      "$_flat"
  else
    "$AAPT_BIN" package -f \
      -M "$_src/AndroidManifest.xml" \
      -S "$_src/res" \
      -I "$FRAMEWORK_RES" \
      -F "$_unsigned"
  fi

  if [ -n "$ZIPALIGN_BIN" ]; then
    "$ZIPALIGN_BIN" -f 4 "$_unsigned" "$_aligned"
  else
    cp "$_unsigned" "$_aligned"
  fi

  "$APKSIGNER_BIN" sign \
    --ks "$KEYSTORE" \
    --ks-key-alias coresurface \
    --ks-pass pass:coresurface \
    --key-pass pass:coresurface \
    --v1-signing-enabled true \
    --v2-signing-enabled true \
    --out "$_final" \
    "$_aligned"

  "$APKSIGNER_BIN" verify "$_final" >/dev/null
  rm -f "${_final}.idsig"
  printf 'Built & verified RRO overlay: %s (%s)\n' "$_apk_name" "$( [ -n "$AAPT2_BIN" ] && printf 'aapt2' || printf 'aapt' )"
}

build_one_overlay "systemui-ui" "CoreSurfaceSystemUI.apk"
build_one_overlay "systemui-lite-blur" "CoreSurfaceSystemUILiteBlur.apk"
build_one_overlay "thememanager" "CoreSurfaceThemeManager.apk"
build_one_overlay "miwallpaper" "CoreSurfaceMiWallpaper.apk"
