#!/bin/sh
# CoreSurface v1.0.0 - Clean-Room Luminous & LivingFlow LSPosed Engine APK Builder (POSIX sh)
# Compiles engine-src/ (Java + AGSL shaders) into a tiny signed APK (~30-45 KB) with
# ZERO external Maven downloads and ZERO binary blobs committed to git.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SRC_DIR="$REPO_ROOT/engine-src"
OUT_DIR=${CORESURFACE_ENGINE_OUT:-"$REPO_ROOT/build/engine"}
APK_NAME="CoreSurfaceEngine.apk"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

find_android_jar() {
  for _sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" /opt/android-sdk /usr/local/lib/android/sdk /usr/lib/android-sdk; do
    if [ -z "$_sdk" ] || [ ! -d "$_sdk/platforms" ]; then
      continue
    fi
    # Prefer API 36 / 35 / 34 (needs API 33+ for RuntimeShader)
    for _api in android-36 android-35 android-34 android-33; do
      if [ -r "$_sdk/platforms/$_api/android.jar" ]; then
        printf '%s\n' "$_sdk/platforms/$_api/android.jar"
        return 0
      fi
    done
    _jar=$(find "$_sdk/platforms" -maxdepth 2 -name android.jar 2>/dev/null | sort | tail -n 1 || true)
    if [ -n "$_jar" ] && [ -r "$_jar" ]; then
      printf '%s\n' "$_jar"
      return 0
    fi
  done
  return 1
}

find_sdk_tool() {
  _tool=$1
  for _sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" /opt/android-sdk /usr/local/lib/android/sdk /usr/lib/android-sdk; do
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

ANDROID_JAR=$(find_android_jar) || {
  printf 'ERROR: Cannot find Android SDK android.jar (API 33+ required for AGSL RuntimeShader)\n' >&2
  exit 1
}

AAPT2_BIN=$(find_sdk_tool aapt2 || true)
D8_BIN=$(find_sdk_tool d8 || true)
ZIPALIGN_BIN=$(find_sdk_tool zipalign || true)
APKSIGNER_BIN=$(find_sdk_tool apksigner || true)

for _req in javac jar keytool zip; do
  if ! command -v "$_req" >/dev/null 2>&1; then
    printf 'ERROR: Required tool not found in PATH: %s\n' "$_req" >&2
    exit 1
  fi
done

if [ -z "$AAPT2_BIN" ] || [ -z "$D8_BIN" ] || [ -z "$APKSIGNER_BIN" ]; then
  printf 'ERROR: Missing Android SDK tools (aapt2=%s d8=%s apksigner=%s)\n' \
    "${AAPT2_BIN:-missing}" "${D8_BIN:-missing}" "${APKSIGNER_BIN:-missing}" >&2
  exit 1
fi

STUB_CLASSES="$WORK_DIR/stub-classes"
APP_CLASSES="$WORK_DIR/app-classes"
GEN_SRC="$WORK_DIR/gen"
DEX_DIR="$WORK_DIR/dex"
mkdir -p "$STUB_CLASSES" "$APP_CLASSES" "$GEN_SRC" "$DEX_DIR" "$OUT_DIR"

# 1. Compile resources + manifest via aapt2 (also emits R.java if needed)
FLAT_RES="$WORK_DIR/res.flata"
BASE_APK="$WORK_DIR/base.apk"
"$AAPT2_BIN" compile --dir "$SRC_DIR/res" -o "$FLAT_RES"
"$AAPT2_BIN" link \
  -I "$ANDROID_JAR" \
  --manifest "$SRC_DIR/AndroidManifest.xml" \
  -A "$SRC_DIR/assets" \
  --java "$GEN_SRC" \
  -o "$BASE_APK" \
  "$FLAT_RES"

# 2. Compile compile-only Xposed API stubs (NEVER packaged into classes.dex)
STUB_SRCS="$WORK_DIR/stub_srcs.list"
find "$SRC_DIR/stubs" -name '*.java' | sort > "$STUB_SRCS"
javac --release 11 -cp "$ANDROID_JAR" -d "$STUB_CLASSES" @"$STUB_SRCS"

# 3. Compile CoreSurface Engine Java sources against android.jar + compile-only stubs
APP_SRCS="$WORK_DIR/app_srcs.list"
{
  find "$SRC_DIR/java" -name '*.java'
  find "$GEN_SRC" -name '*.java'
} | sort > "$APP_SRCS"

javac --release 11 -Xlint:all,-processing -Werror -cp "${ANDROID_JAR}:${STUB_CLASSES}" -d "$APP_CLASSES" @"$APP_SRCS"

# 4. Dex compiled engine classes only (excluding Xposed stubs) with d8
APP_JAR="$WORK_DIR/engine-classes.jar"
jar cf "$APP_JAR" -C "$APP_CLASSES" .
"$D8_BIN" --release --min-api 31 --lib "$ANDROID_JAR" --output "$DEX_DIR" "$APP_JAR"

if [ ! -f "$DEX_DIR/classes.dex" ]; then
  printf 'ERROR: d8 did not produce classes.dex\n' >&2
  exit 1
fi

# 5. Inject classes.dex into linked APK
cp "$BASE_APK" "$WORK_DIR/unsigned.apk"
(
  cd "$DEX_DIR"
  zip -q -u "$WORK_DIR/unsigned.apk" classes.dex
)

# 6. Align APK
ALIGNED_APK="$WORK_DIR/aligned.apk"
if [ -n "$ZIPALIGN_BIN" ]; then
  "$ZIPALIGN_BIN" -f 4 "$WORK_DIR/unsigned.apk" "$ALIGNED_APK"
else
  cp "$WORK_DIR/unsigned.apk" "$ALIGNED_APK"
fi

# 7. Sign APK with ephemeral clean-room keystore (v1 + v2 + v3)
KEYSTORE="$WORK_DIR/coresurface-engine.jks"
keytool -genkeypair \
  -v \
  -keystore "$KEYSTORE" \
  -alias coresurface_engine \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -storepass coresurface \
  -keypass coresurface \
  -dname "CN=CoreSurfaceEngine, OU=LuminousLivingFlow, O=Mystivara, L=Unknown, S=Unknown, C=ID" >/dev/null 2>&1

FINAL_APK="$OUT_DIR/$APK_NAME"
rm -f "$FINAL_APK" "${FINAL_APK}.idsig"

"$APKSIGNER_BIN" sign \
  --ks "$KEYSTORE" \
  --ks-key-alias coresurface_engine \
  --ks-pass pass:coresurface \
  --key-pass pass:coresurface \
  --v1-signing-enabled true \
  --v2-signing-enabled true \
  --v3-signing-enabled true \
  --out "$FINAL_APK" \
  "$ALIGNED_APK"

"$APKSIGNER_BIN" verify "$FINAL_APK" >/dev/null
rm -f "${FINAL_APK}.idsig"

_size=$(wc -c < "$FINAL_APK" | tr -d ' \t\r\n')
printf 'Built & verified CoreSurface Engine APK: %s (%s bytes)\n' "$FINAL_APK" "$_size"
