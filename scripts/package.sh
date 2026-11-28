#!/bin/sh
# CoreSurface - Production Module ZIP Packager (POSIX sh)
# Builds 5 clean-room RRO overlays and packages whitelisted standalone files
# into dist/CoreSurface-<version>.zip ready to flash on KernelSU-Next, Magisk, APatch, & Recovery.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DIST_DIR="$REPO_ROOT/dist"
OVERLAY_BUILD_DIR="$REPO_ROOT/build/overlays"
VERSION=$(awk -F '=' '$1 == "version" { print $2; exit }' "$REPO_ROOT/module.prop")
ZIP_NAME="CoreSurface-${VERSION}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="${ZIP_PATH}.sha256"

STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT INT TERM

# 1. Compile and sign clean-room RRO overlays from overlays-src/
CORESURFACE_OVERLAY_OUT="$OVERLAY_BUILD_DIR" sh "$REPO_ROOT/scripts/build_overlays.sh"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH" "$SHA_PATH" "$DIST_DIR/CoreSurfaceEngine.apk"

# Strict whitelist of production module files (100% standalone pure user-space)
for item in \
  META-INF \
  module.prop \
  customize.sh \
  post-fs-data.sh \
  service.sh \
  action.sh \
  uninstall.sh \
  LICENSE \
  README.md \
  lib \
  defaults \
  webroot
do
  if [ ! -e "$REPO_ROOT/$item" ]; then
    printf 'ERROR: Required release item missing: %s\n' "$item" >&2
    exit 1
  fi
  cp -R "$REPO_ROOT/$item" "$STAGE_DIR/"
done

# Copy compiled clean-room RRO APKs into overlays/ inside the release ZIP
mkdir -p "$STAGE_DIR/overlays"
cp "$OVERLAY_BUILD_DIR"/CoreSurface*.apk "$STAGE_DIR/overlays/"
chmod 0644 "$STAGE_DIR/overlays"/CoreSurface*.apk

# Ensure executable bit on shell entrypoints inside staging
chmod 0755 \
  "$STAGE_DIR/META-INF/com/google/android/update-binary" \
  "$STAGE_DIR/customize.sh" \
  "$STAGE_DIR/post-fs-data.sh" \
  "$STAGE_DIR/service.sh" \
  "$STAGE_DIR/action.sh" \
  "$STAGE_DIR/uninstall.sh" \
  "$STAGE_DIR/lib/detect.sh" \
  "$STAGE_DIR/lib/watchdog.sh" \
  "$STAGE_DIR/lib/props.sh" \
  "$STAGE_DIR/lib/xml_patcher.sh" \
  "$STAGE_DIR/lib/rro.sh" \
  "$STAGE_DIR/lib/settings_tx.sh" \
  "$STAGE_DIR/lib/verifier.sh" \
  "$STAGE_DIR/lib/os_bug_logic.sh" \
  "$STAGE_DIR/lib/camera_probe.sh" \
  "$STAGE_DIR/lib/webui_ctl.sh"

(
  cd "$STAGE_DIR"
  zip -r -9 -q "$ZIP_PATH" .
)

(
  cd "$DIST_DIR"
  sha256sum "$ZIP_NAME" > "$SHA_PATH"
)

# Verify flash-readiness: required Magisk/KSU/APatch artifacts present & zero dev files leaked
ZIP_LIST=$(unzip -Z1 "$ZIP_PATH")
for req in \
  "META-INF/com/google/android/update-binary" \
  "META-INF/com/google/android/updater-script" \
  "module.prop" \
  "customize.sh" \
  "post-fs-data.sh" \
  "service.sh" \
  "action.sh" \
  "uninstall.sh" \
  "lib/camera_probe.sh" \
  "overlays/CoreSurfaceSystemUI.apk" \
  "overlays/CoreSurfaceSystemUILiteBlur.apk" \
  "overlays/CoreSurfaceThemeManager.apk" \
  "overlays/CoreSurfaceMiWallpaper.apk" \
  "overlays/CoreSurfaceMiuiAod.apk"
do
  if ! printf '%s\n' "$ZIP_LIST" | grep -F -x -q "$req"; then
    printf 'ERROR: Missing required flashable entry in %s: %s\n' "$ZIP_PATH" "$req" >&2
    exit 1
  fi
done

if printf '%s\n' "$ZIP_LIST" | grep -E '^(tests/|\.github/|scripts/|dist/|build/|overlays-src/|engine/|engine-src/|\.git/)' >/dev/null 2>&1; then
  printf 'ERROR: Development or legacy engine files leaked into %s\n' "$ZIP_PATH" >&2
  exit 1
fi

printf 'Built & verified flash-ready artifact: %s\n' "$ZIP_PATH"
cat "$SHA_PATH"
