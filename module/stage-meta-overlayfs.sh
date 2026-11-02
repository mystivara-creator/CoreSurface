#!/system/bin/sh
# Early staging into meta-overlayfs ext4 image, before its metamount.sh executes.
set -eu
M=${0%/*}
META=/data/adb/metamodule
STOCK=/product/etc/device_features/kunzite.xml
SRC="$M/product/etc/device_features/kunzite.xml"
[ -s "$SRC" ] || { echo 'MISSING_STAGED_XML'; exit 21; }
[ -r "$META/module.prop" ] && grep -qx 'id=meta-overlayfs' "$META/module.prop" || { echo 'UNSUPPORTED_METAMODULE'; exit 22; }
[ -s "$META/modules.img" ] || { echo 'MISSING_METAMODULE_IMAGE'; exit 23; }
# Don't rewrite backing files if product is already overlaid in this namespace.
if grep -Eq '[[:space:]]/product[[:space:]]overlay[[:space:]]' /proc/mounts; then
  echo 'PRODUCT_ALREADY_OVERLAID'; exit 24
fi
MNT="$META/mnt"
mkdir -p "$MNT"
if ! mountpoint -q "$MNT"; then
  chcon u:object_r:ksu_file:s0 "$META/modules.img" 2>/dev/null || true
  mount -t ext4 -o loop,rw,noatime "$META/modules.img" "$MNT" || { echo 'IMAGE_MOUNT_FAILED'; exit 25; }
fi
DEST="$MNT/kunzite_wcg_probe/product/etc/device_features"
mkdir -p "$DEST"
TMP="$DEST/kunzite.xml.tmp"
cp "$SRC" "$TMP" || exit 26
chmod 0644 "$TMP"
chcon --reference="$STOCK" "$TMP" 2>/dev/null || true
mv -f "$TMP" "$DEST/kunzite.xml" || exit 27
cmp -s "$SRC" "$DEST/kunzite.xml" || { echo 'STAGED_XML_MISMATCH'; exit 28; }
# Only authorize the metamodule when image content exists and matches.
rm -f "$M/skip_mount"
echo 'META_OVERLAY_STAGED'
