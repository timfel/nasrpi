#!/usr/bin/env bash
# 03_setup_smartmontools.sh
# - monitor all physical disks with smartd (entries via /dev/disk/by-uuid)
# - defer self-tests while disks are idle/spun-down (smartd -d maint)
# - smartd mails alerts itself (sendmail = msmtp shim from step 02)
# - plus a -M exec handler: on any alert smartd runs it with the device as
#   argument and the report on stdin; it logs and (optionally) unmounts the
#   failing disk. No separate cron checker needed.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

SMARTCTL_CFG="$NASRPI_ETC_DIR/smartd.conf"
ALERT_BIN="/usr/local/bin/nasrpi-smartd-alert.sh"   # write_file applies the dry-run shadow

say "03 - smartmontools"
apt_install smartmontools   # sendmail (msmtp-mta) comes from step 02

ask NOTIFY_EMAIL "Address to receive SMART alerts" "root"

# --- which disks to monitor -----------------------------------------------------
# smartd entries use stable /dev/disk/by-uuid/<uuid> paths where a filesystem
# UUID exists (survives reconnects/port changes); falls back to /dev/sdX.
DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
MON=()
for d in $DISKS; do
  u=$(lsblk -rno UUID "$d" 2>/dev/null | grep -m1 . || true)
  if [ -n "$u" ]; then
    MON+=("/dev/disk/by-uuid/$u")
    echo "  $d -> /dev/disk/by-uuid/$u"
  else
    warn "no filesystem UUID on $d -- monitoring by name (may change on reconnect)"
    MON+=("$d")
  fi
done

ALERT_OPTS="-M exec $ALERT_BIN \$DEVICE"

build_smartd() {
  echo "# Managed by nasrpi setup scripts -- rerun 03 after adding/removing disks."
  echo "# -a : all SMART checks, -m : mail via sendmail, -s : short/long self-tests,"
  echo "# -o on : auto-offline data collection, -d maint : only run self-tests during"
  echo "# maintenance windows, so idle/spun-down disks are NOT spun up for testing."
  echo "# -I <id> : mail immediately whenever these raw attributes change --"
  echo "# zero tolerance: 5 reallocated, 187 uncorrected, 197 pending, 198 uncorrectable."
  echo "# -M exec : run the nasrpi alert handler (device as arg, report on stdin)."
  local d
  for d in "${MON[@]}"; do
    echo "$d -n standby,q -a -m $NOTIFY_EMAIL -o on -s (S/../.././09|L/../../6/10) -d maint -I 5 -I 187 -I 197 -I 198 $ALERT_OPTS"
  done
}

# replace our previously managed block, keep any hand-written lines
existing=""
if [ -f "$SMARTCTL_CFG" ]; then
  existing=$(grep -v '^# Managed by nasrpi' "$SMARTCTL_CFG" \
             | grep -v ' -d maint' || true)
fi
{ [ -n "$existing" ] && echo "$existing"; build_smartd; } | write_file 644 "$SMARTCTL_CFG" "sudo" || true

if [ "${DRY_RUN:-0}" != "1" ]; then
  if confirm "Restart the smartmontools service now?"; then
    $NASRPI_SUDO systemctl restart smartmontools && ok "smartmontools restarted"
  fi
fi

# --- alert handler ---------------------------------------------------------------
# smartd runs it for every alert it mails, e.g.:
#   nasrpi-smartd-alert.sh /dev/disk/by-uuid/xxxx   (full report on stdin)
# With -M exec smartd hands the alert mail to the handler INSTEAD of mailing
# it itself -- the handler logs, unmounts, and mails the report via sendmail.
ask AUTO_UNMOUNT "Auto-unmount disks when smartd reports a failure? (else log/mail only)" "y"

cat <<EOF | write_file 755 "$ALERT_BIN" "sudo"
#!/bin/sh
# nasrpi: smartd alert handler (-M exec target).
# Called by smartd as:  \$0 <device>   with the alert report on stdin.
# IMPORTANT: with -M exec, smartd pipes the mail to US INSTEAD of mailing
# it -- this handler IS the mailer. We log, unmount, then send via
# sendmail (msmtp shim from step 02).
# Managed by nasrpi setup scripts (03). Set AUTO_UNMOUNT=no below for
# alert-only behaviour (no unmounting).
AUTO_UNMOUNT=$([ "$AUTO_UNMOUNT" = "y" ] && echo yes || echo no)
NOTIFY_EMAIL=$NOTIFY_EMAIL       # fallback recipient if SMARTD_ADDRESS is unset
DEV="\${1:-\$SMARTD_DEVICE}"
LOG=/var/log/nasrpi-smart-alert.log

REPORT=\$(cat)          # the alert report smartd piped in on stdin

{
  echo "===== \$(date '+%F %T') SMART alert for \$DEV ====="
  echo "\$REPORT"
  echo
} >> "\$LOG" 2>/dev/null || true

NOTES=""
if [ "\$AUTO_UNMOUNT" = yes ]; then
  NOTES=\$(
    for mp in \$(lsblk -rno MOUNTPOINT "\$DEV" 2>/dev/null | grep .); do
      if umount -R "\$mp" 2>/dev/null; then
        echo "nasrpi: UNMOUNTED \$mp (failing disk \$DEV)"
      else
        echo "nasrpi: could NOT unmount \$mp (failing disk \$DEV)"
      fi
    done
  )
fi

# we are the mailer now: send the report plus our notes
{
  echo "To: \${SMARTD_ADDRESS:-\$NOTIFY_EMAIL}"
  echo "Subject: \${SMARTD_SUBJECT:-nasrpi: SMART alert for \$DEV}"
  echo
  [ -n "\$NOTES" ] && echo "\$NOTES"
  echo "nasrpi: SMART alert for \$DEV at \$(date '+%F %T'); full report also in \$LOG."
  echo
  echo "\$REPORT"
} | sendmail -t || echo "nasrpi: FAILED to mail SMART alert for \$DEV" >&2
EOF

say "03 done. Test with: echo test | sudo $ALERT_BIN /dev/sda"
