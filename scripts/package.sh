#!/bin/sh
# CoreSurface v1.0.0 - Production Module ZIP Packager (POSIX sh)
# Packages only whitelisted production module files into dist/CoreSurface-v1.0.0.zip.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DIST_DIR="$REPO_ROOT/dist"
VERSION=$(awk -F '=' '$1 == "version" { print $2; exit }' "$REPO_ROOT/module.prop")
ZIP_NAME="CoreSurface-${VERSION}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="${ZIP_PATH}.sha256"

STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT INT TERM

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH" "$SHA_PATH"

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

# Ensure executable bit on shell entrypoints inside staging
chmod 0755 \
  "$STAGE_DIR/customize.sh" \
  "$STAGE_DIR/post-fs-data.sh" \
  "$STAGE_DIR/service.sh" \
  "$STAGE_DIR/uninstall.sh" \
  "$STAGE_DIR/lib/detect.sh" \
  "$STAGE_DIR/lib/watchdog.sh" \
  "$STAGE_DIR/lib/props.sh" \
  "$STAGE_DIR/lib/webui_ctl.sh"

(
  cd "$STAGE_DIR"
  zip -r -9 -q "$ZIP_PATH" .
)

(
  cd "$DIST_DIR"
  sha256sum "$ZIP_NAME" > "$SHA_PATH"
)

# Verify no dev files leaked into the ZIP (unzip -Z1 lists entry paths only)
if unzip -Z1 "$ZIP_PATH" | grep -E '^(tests/|\.github/|scripts/|dist/|\.git/)' >/dev/null 2>&1; then
  printf 'ERROR: Development files leaked into %s\n' "$ZIP_PATH" >&2
  exit 1
fi

printf 'Built production artifact: %s\n' "$ZIP_PATH"
cat "$SHA_PATH"
