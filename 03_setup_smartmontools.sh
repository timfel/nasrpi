#!/usr/bin/env bash
# 03_setup_smartmontools.sh
# - monitor all physical disks with smartd
# - defer self-tests while disks are idle/spun-down (smartd -d maint)
# - mail alerts via sendmail when anything degrades
# - daily checker: if SMART reports reallocation/read-error failures,
#   unmount the affected drive and mail a report
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

SMARTCTL_CFG="$NASRPI_ETC_DIR/smartd.conf"
CHECKER=/usr/local/bin/nasrpi-smart-check.sh

say "03 - smartmontools"
apt_install smartmontools mailutils

ask NOTIFY_EMAIL "Address to receive SMART alerts" "root"

# --- which disks to monitor -----------------------------------------------------
DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
echo "$DISKS" | sed 's/^/  /'

build_smartd() {
  echo "# Managed by nasrpi setup scripts -- rerun 03 after adding/removing disks."
  echo "# -a : all SMART checks, -m : mail via sendmail, -s : short/long self-tests,"
  echo "# -o on : auto-offline data collection, -d maint : only run self-tests during"
  echo "# maintenance windows, so idle/spun-down disks are NOT spun up for testing."
  echo "# -I <id> : mail immediately whenever these raw attributes change --"
  echo "# zero tolerance: 5 reallocated, 187 uncorrected, 197 pending, 198 uncorrectable."
  local d
  for d in $DISKS; do
    echo "$d -a -m $NOTIFY_EMAIL -o on -s (S/../.././02|L/../../6/03) -d maint -I 5 -I 187 -I 197 -I 198"
  done
}

# replace our previously managed block, keep any hand-written lines
existing=""
if [ -f "$SMARTCTL_CFG" ]; then
  existing=$(grep -v '^# Managed by nasrpi' "$SMARTCTL_CFG" \
             | grep -v '^\S* -a -m .* -d maint' || true)
fi
{ [ -n "$existing" ] && echo "$existing"; build_smartd; } | write_file 644 "$SMARTCTL_CFG" || true

if [ "${DRY_RUN:-0}" != "1" ]; then
  if confirm "Restart smartd now?"; then
    systemctl restart smartd && ok "smartd restarted"
  fi
fi

# --- failure checker: unmount drives with real failure indicators ----------------
ask AUTO_UNMOUNT "Auto-unmount disks that show SMART failure indicators? (else alert only)" "y"

tmp=$(mktemp)
cat > "$tmp" <<EOF
#!/bin/sh
# nasrpi: daily SMART check. Mails a report; unmounts disks on real failures.
# Managed by nasrpi setup scripts (03). Edit AUTO_UNMOUNT here to change policy.
AUTO_UNMOUNT=$([ "$AUTO_UNMOUNT" = "y" ] && echo yes || echo no)
NOTIFY_EMAIL=$NOTIFY_EMAIL
REPORT=\$(mktemp)
FAILED=0

# ZERO TOLERANCE: even a single reallocated/pending/uncorrected sector counts
# as failure. Edit FAIL_ATTRS to tune (smartctl attribute names).
FAIL_ATTRS="Reallocated_Sector_Ct Reallocated_Sector_Event_Count Reported_Uncorrect Current_Pending_Sector Offline_Uncorrectable"

for dev in \$(lsblk -dno NAME,TYPE | awk '\$2=="disk"{print "/dev/"\$1}'); do
  smartctl -q nodev "\$dev" >/dev/null 2>&1 && continue   # disk gone / USB pulled
  out=\$(smartctl -H -l error -A "\$dev" 2>&1)
  reason=""
  echo "\$out" | grep -qiE 'SMART overall-health.*FAILED|SMART Failure Detected' \
    && reason="\$reason overall-health-FAILED"
  # any recorded read/handle error in the error log counts
  echo "\$out" | grep -qE 'ATA Error Count:[[:space:]]*[1-9]' \
    && reason="\$reason error-log-errors"
  # zero tolerance on raw values of the attributes above
  for attr in \$FAIL_ATTRS; do
    raw=\$(echo "\$out" | awk -v a="\$attr" '\$2==a {print \$NF; exit}')
    case "\$raw" in
      ''|*[!0-9]*) : ;;   # empty, '-' or hex-encoded: not countable, skip
      *) [ "\$raw" -gt 0 ] && reason="\$reason \$attr=\$raw" ;;
    esac
  done
  if [ -n "\$reason" ]; then
    FAILED=1
    {
      echo "=== SMART FAILURE on \$dev:\$reason ==="
      echo "\$out"
    } >> "\$REPORT"
    if [ "\$AUTO_UNMOUNT" = yes ]; then
      for mp in \$(lsblk -rno MOUNTPOINT "\$dev" | grep .); do
        if umount -R "\$mp" 2>> "\$REPORT"; then
          echo "unmounted \$mp (failing disk \$dev)" >> "\$REPORT"
        else
          echo "could NOT unmount \$mp (failing disk \$dev)" >> "\$REPORT"
        fi
      done
    fi
  fi
done

if [ "\$FAILED" = 1 ]; then
  cat "\$REPORT" | mail -s "nasrpi: SMART failure detected on \$(hostname)" "\$NOTIFY_EMAIL"
fi
rm -f "\$REPORT"
EOF
write_file 755 "$CHECKER" < "$tmp"
rm -f "$tmp"

ask_dow_hour SMART
install_cron nasrpi-smart "$SMART_DOW $SMART_HOUR $SMART_MIN" "$CHECKER"

say "03 done. Test with: sudo smartctl -a /dev/sda"
