#!/system/bin/sh
# Read-only report: no system-property, sysfs, mount, or driver changes.
set -u
OUT=${1:-/sdcard/Download/kunzite-vulkan-audit}
mkdir -p "$OUT" || exit 1
umask 077
{
  printf 'device=%s\n' "$(getprop ro.product.device)"
  printf 'board=%s\n' "$(getprop ro.board.platform)"
  printf 'rom=%s\n' "$(getprop ro.system.build.version.incremental)"
  printf 'vulkan_driver=%s\n' "$(getprop ro.hardware.vulkan)"
  pm list features 2>/dev/null | grep 'feature:android.hardware.vulkan' || true
} > "$OUT/android-identification.txt"
{
  for p in /vendor/lib64/hw/vulkan.*.so /odm/lib64/hw/vulkan.*.so /system/lib64/hw/vulkan.*.so; do
    if [ -f "$p" ]; then
      ls -l "$p"
      sha256sum "$p" 2>/dev/null || true
    fi
  done
} > "$OUT/vulkan-driver-files.txt"
if command -v vulkaninfo >/dev/null 2>&1; then
  vulkaninfo --summary > "$OUT/vulkaninfo-summary.txt" 2>&1 || true
  vulkaninfo > "$OUT/vulkaninfo-full.txt" 2>&1 || true
else
  echo 'vulkaninfo unavailable: extension and feature bits remain unverified.' > "$OUT/vulkaninfo-unavailable.txt"
fi
dumpsys gpu 2>&1 | grep -iE 'vulkan|driver|angle|gpu' | head -n 80 > "$OUT/android-gpu.txt" || true
printf 'Audit saved: %s\n' "$OUT"
