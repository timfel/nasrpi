#!/usr/bin/env bash
# 03_setup_smartmontools.sh
# - NO smartd: the daemon wakes USB disks constantly, and some of them spin
#   up even when smartd only asks "are you spinning?" (-n standby) -- so the
#   daemon is worse than useless here. We do NOT run smartd and do not
#   touch /etc/smartd.conf.
# - instead: a daily cron job runs smartctl ONCE per disk (one spin-up per
#   disk per day at most, at a time of day you pick), mails you the status,
#   and greps the report for the bad indicators (raw values of SMART attrs
#   5, 187, 197, 198 and the overall-health verdict). If any of them has
#   gone above 0, the mail goes out with an ALARM ALARM ALARM subject line.
# - the report simply walks /dev/sd? at runtime: every whole disk gets
#   checked, so it does not matter if reconnects reshuffle the names.
# - smartmontools is still installed (it provides smartctl); if a smartd
#   service from an earlier setup is still running, we disable it.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

REPORT_BIN="/usr/local/bin/nasrpi-smart-report.sh"

say "03 - SMART daily report (no smartd)"
apt_install smartmontools   # provides smartctl; sendmail (msmtp-mta) comes from step 02

ask NOTIFY_EMAIL "Address to receive SMART reports" "root"

# --- make sure the smartd daemon is gone -----------------------------------------
# The package installs and enables smartd; smartd polls disks all day and
# wakes them up. If it is around from an earlier setup, disable it.
if [ "${DRY_RUN:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
  if $NASRPI_SUDO systemctl is-enabled smartmontools >/dev/null 2>&1 \
     || $NASRPI_SUDO systemctl is-active smartmontools >/dev/null 2>&1; then
    warn "smartd is active/enabled -- it wakes USB disks constantly."
    if confirm "Disable the smartd service (the daily cron report replaces it)?"; then
      $NASRPI_SUDO systemctl disable --now smartmontools && ok "smartd disabled"
    fi
  else
    ok "smartd is not enabled"
  fi
fi

# --- daily SMART status report --------------------------------------------------
# One smartctl -a per disk per day; greps the bad indicators out of the
# output. Zero tolerance: any non-zero raw value for attrs 5 (reallocated
# sectors), 187 (reported uncorrect), 197 (pending sectors) or 198
# (offline uncorrectable) -- or a FAILED overall-health line -- is an ALARM.
REPORT_TMP=$(mktemp)
cat <<'EOF' > "$REPORT_TMP"
#!/bin/bash
set -u
TO=__NOTIFY_EMAIL__
SENDMAIL=${SENDMAIL:-/usr/sbin/sendmail}
BAD_ATTRS="5 187 197 198"   # raw value must stay at zero, no exceptions
TMP=$(mktemp)
BADLIST=$(mktemp)
trap 'rm -f "$TMP" "$BADLIST"' EXIT

{
  echo "nasrpi daily SMART status - $(date '+%F')"
  echo
  shopt -s nullglob
  found=0
  for dev in /dev/sd?; do
    # whole disks only: sdX with no partition number
    found=1
    echo "===== $dev ====="
    if ! out=$(smartctl -a "$dev" 2>&1); then
      echo "WARNING: smartctl returned an error for $dev"
      echo "$out"
    fi
    # overall health verdict + the attribute rows we watch
    echo "$out" | grep -i 'SMART overall-health' || echo "overall health: (not reported)"
    printf '%s\n' "$out" | awk '$1=="ID#" || $1 ~ /^(5|187|197|198)$/'
    # zero-tolerance probe: has any bad indicator gone above 0?
    bad=0
    for a in $BAD_ATTRS; do
      raw=$(printf '%s\n' "$out" | awk -v id="$a" '$1==id {print $NF; exit}')
      case "$raw" in
        ''|*[!0-9]*) ;;                              # not a plain number -> ignore
        *) if [ "$raw" -gt 0 ]; then
             echo "$dev: attribute $a raw value $raw (must be 0)" >> "$BADLIST"
             bad=1
           fi ;;
      esac
    done
    if printf '%s\n' "$out" | grep -qi 'SMART overall-health.*FAILED'; then
      echo "$dev: overall-health self-assessment FAILED" >> "$BADLIST"
      bad=1
    fi
    [ "$bad" -eq 1 ] && echo ">>> ALARM ALARM ALARM: bad indicators on $dev"
    echo
  done
  [ "$found" -eq 1 ] || echo "No /dev/sd? disks found."
} > "$TMP" 2>&1

# ALARM subject line when any watched indicator went above 0
if [ -s "$BADLIST" ]; then
  alarms=$(cut -d: -f1 < "$BADLIST" | sort -u | tr '\n' ' ')
  SUBJECT="ALARM ALARM ALARM - nasrpi SMART ($alarms) - $(date '+%F')"
else
  SUBJECT="nasrpi daily SMART status - $(date '+%F')"
fi
{
  echo "To: $TO"
  echo "Subject: $SUBJECT"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo
  if [ -s "$BADLIST" ]; then
    echo "ALARM ALARM ALARM - a watched SMART indicator has gone above zero:"
    cat "$BADLIST"
    echo
  fi
  cat "$TMP"
} | "$SENDMAIL" -t
EOF
# Substitute the recipient address (administrator-provided value).
sed -e "s|__NOTIFY_EMAIL__|$NOTIFY_EMAIL|g" "$REPORT_TMP" \
  | write_file 755 "$REPORT_BIN" "sudo" "force"
rm -f "$REPORT_TMP"

ask SMART_REPORT_HOUR "Daily SMART report hour (0-23)" "7"
[[ "$SMART_REPORT_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || die "hour must be 0-23"
# Install directly: /etc/cron.d supports daily timing independent of weekly helpers.
install_cron nasrpi-smart-report "* $SMART_REPORT_HOUR 0" "/usr/local/bin/nasrpi-smart-report.sh"

say "03 done. Test with: sudo $REPORT_BIN
The report mails daily at :$SMART_REPORT_HOUR; disks sleep the rest of the
time because nothing polls them. To tweak the watched attributes or the
recipient, edit the top of $REPORT_BIN."
