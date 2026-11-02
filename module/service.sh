#!/system/bin/sh
# No persistent daemon. Mark a completed boot to avoid erroneous rollback.
M=${0%/*}
[ -f "$M/boot_pending" ] || exit 0
n=0
while [ "$n" -lt 120 ]; do
  [ "$(getprop sys.boot_completed)" = 1 ] && {
    rm -f "$M/boot_pending"
    echo 'EXPERIMENTAL_BOOT_COMPLETED: verify features in Settings/Camera' >> "$M/boot_result.txt"
    exit 0
  }
  sleep 2
  n=$((n+1))
done
# Pending remains and experiments revert on the following boot attempt.
