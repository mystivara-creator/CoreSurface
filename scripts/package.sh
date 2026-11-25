#!/bin/sh
# CoreSurface v1.0.0 - Production Module ZIP Packager (POSIX sh)
# Builds clean-room RRO overlays + clean-room Flagship Motion Engine APK
# and packages whitelisted production files into dist/CoreSurface-v1.0.0.zip.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DIST_DIR="$REPO_ROOT/dist"
OVERLAY_BUILD_DIR="$REPO_ROOT/build/overlays"
ENGINE_BUILD_DIR="$REPO_ROOT/build/engine"
VERSION=$(awk -F '=' '$1 == "version" { print $2; exit }' "$REPO_ROOT/module.prop")
ZIP_NAME="CoreSurface-${VERSION}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="${ZIP_PATH}.sha256"

STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT INT TERM

# 1. Compile and sign clean-room RRO overlays from overlays-src/
CORESURFACE_OVERLAY_OUT="$OVERLAY_BUILD_DIR" sh "$REPO_ROOT/scripts/build_overlays.sh"

# 2. Compile and sign clean-room Flagship Motion LSPosed Engine APK from engine-src/
CORESURFACE_ENGINE_OUT="$ENGINE_BUILD_DIR" sh "$REPO_ROOT/scripts/build_engine.sh"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH" "$SHA_PATH" "$DIST_DIR/CoreSurfaceEngine.apk"

# Strict whitelist of production module files
for item in \
  module.prop \
  customize.sh \
  post-fs-data.sh \
  service.sh \
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

# Copy compiled clean-room Engine APK into engine/ inside the release ZIP and also dist/
mkdir -p "$STAGE_DIR/engine"
cp "$ENGINE_BUILD_DIR/CoreSurfaceEngine.apk" "$STAGE_DIR/engine/CoreSurfaceEngine.apk"
chmod 0644 "$STAGE_DIR/engine/CoreSurfaceEngine.apk"
cp "$ENGINE_BUILD_DIR/CoreSurfaceEngine.apk" "$DIST_DIR/CoreSurfaceEngine.apk"

# Ensure executable bit on shell entrypoints inside staging
chmod 0755 \
  "$STAGE_DIR/customize.sh" \
  "$STAGE_DIR/post-fs-data.sh" \
  "$STAGE_DIR/service.sh" \
  "$STAGE_DIR/uninstall.sh" \
  "$STAGE_DIR/lib/detect.sh" \
  "$STAGE_DIR/lib/watchdog.sh" \
  "$STAGE_DIR/lib/props.sh" \
  "$STAGE_DIR/lib/xml_patcher.sh" \
  "$STAGE_DIR/lib/rro.sh" \
  "$STAGE_DIR/lib/settings_tx.sh" \
  "$STAGE_DIR/lib/verifier.sh" \
  "$STAGE_DIR/lib/os_bug_logic.sh" \
  "$STAGE_DIR/lib/webui_ctl.sh"

(
  cd "$STAGE_DIR"
  zip -r -9 -q "$ZIP_PATH" .
)

(
  cd "$DIST_DIR"
  sha256sum "$ZIP_NAME" > "$SHA_PATH"
)

# Verify no dev/source files leaked into the ZIP (unzip -Z1 lists entry paths only)
if unzip -Z1 "$ZIP_PATH" | grep -E '^(tests/|\.github/|scripts/|dist/|build/|overlays-src/|engine-src/|\.git/)' >/dev/null 2>&1; then
  printf 'ERROR: Development files leaked into %s\n' "$ZIP_PATH" >&2
  exit 1
fi

printf 'Built production artifact: %s\n' "$ZIP_PATH"
cat "$SHA_PATH"
