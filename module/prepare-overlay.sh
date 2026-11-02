#!/system/bin/sh
# Deterministically stage XML from the exact ROM-specific audited baseline.
set -eu
M=${0%/*}
# Fail closed until payload is safely copied to the metamodule image.
: > "$M/skip_mount"
BASE="$M/baseline/kunzite.xml"
EXPERT=0
[ -f "$M/expert_enabled" ] && EXPERT=1
if [ "$EXPERT" -eq 0 ]; then
  # No XML override when Expert Mode is disabled.
  : > "$M/skip_mount"
  rm -rf "$M/product" "$M/system" 
  exit 0
fi
[ -s "$BASE" ] || exit 10
[ "$(grep -o '<bool name="support_display_expert_mode">false</bool>' "$BASE" | wc -l)" -eq 1 ] || exit 11
DSTDIR="$M/product/etc/device_features"
mkdir -p "$DSTDIR"
TMP="$DSTDIR/kunzite.xml.tmp"
cp "$BASE" "$TMP"
if [ "$EXPERT" -eq 1 ]; then
 sed -i 's/<bool name="support_display_expert_mode">false<\/bool>/<bool name="support_display_expert_mode">true<\/bool>/' "$TMP"
 grep -q '<bool name="support_display_expert_mode">true</bool>' "$TMP" || exit 13
fi
chmod 0644 "$TMP"
mv -f "$TMP" "$DSTDIR/kunzite.xml"
# leave skip_mount in place until image-stage succeeded
