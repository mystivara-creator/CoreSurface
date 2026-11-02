#!/system/bin/sh
# Validate systemless experiment overlays after boot. No persistent daemon.
M=${0%/*}
[ -f "$M/boot_pending" ] || exit 0
n=0
while [ "$n" -lt 120 ]; do
  if [ "$(getprop sys.boot_completed)" = 1 ]; then
    # A successful Android boot alone does not prove that meta-overlayfs
    # mounted our feature XML. Check the effective values, not staged files.
    XML=/product/etc/device_features/kunzite.xml
    PROBLEM=
    if [ ! -r "$XML" ]; then
      PROBLEM='OEM_XML_UNREADABLE'
    elif [ -f "$M/expert_enabled" ] && ! grep -Fq '<bool name="support_display_expert_mode">true</bool>' "$XML"; then
      PROBLEM='EXPERT_FLAG_NOT_MOUNTED'
    fi
    if [ -n "$PROBLEM" ]; then
      # Keep boot_pending so post-fs-data can safely unstage the overlay
      # on the next boot. Do not delete live overlay backing files now.
      echo "EXPERIMENTAL_RUNTIME_FAILED: $PROBLEM; rollback staged for next boot" >> "$M/boot_result.txt"
      echo "$PROBLEM" > "$M/recovery_reason"
      exit 1
    fi
    rm -f "$M/boot_pending"
    echo 'EXPERIMENTAL_XML_VERIFIED: expected flags visible; Settings/Camera UI still unverified' >> "$M/boot_result.txt"
    exit 0
  fi
  sleep 2
  n=$((n+1))
done
# Pending remains and experiments revert on the following boot attempt.
