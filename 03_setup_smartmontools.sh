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
REPORT_BIN="/usr/local/bin/nasrpi-smart-report.sh"

say "03 - smartmontools"
apt_install smartmontools   # sendmail (msmtp-mta) comes from step 02

ask NOTIFY_EMAIL "Address to receive SMART alerts" "root"

# --- which disks to monitor -----------------------------------------------------
# smartd entries use stable /dev/disk/by-uuid/<uuid> paths where a filesystem
# UUID exists (survives reconnects/port changes); falls back to /dev/sdX.
MON=()
declare -A seen        # avoid double-monitoring the same disk via id aliases
BY_ID_DIR="${NASRPI_BY_ID_DIR:-/dev/disk/by-id}"   # test hook: fake by-id tree
for link in "$BY_ID_DIR"/ata*; do
  [ -L "$link" ] || continue
  tgt=$(readlink -f "$link")
  # keep only whole /dev/sdX disks (no partitions, no mmcblk/nvme/loop/dm)
  case ${tgt#/dev/} in
    sd[a-z]*) ;;                                  # looks like sdX...
    *) continue ;;
  esac
  [[ $tgt =~ ^/dev/sd[a-z]+$ ]] || continue       # ...and not sdX1/part-style
  [[ -n ${seen[$tgt]:-} ]] && continue            # already have an id for this disk
  seen[$tgt]=1
  MON+=("$link")
  echo "  $tgt -> $link"
done
[ ${#MON[@]} -eq 0 ] && warn "no /dev/disk/by-id entries pointing to /dev/sdX disks"

build_smartd() {
  echo "# Managed by nasrpi setup scripts -- rerun 03 after adding/removing disks."
  local d
  for d in "${MON[@]}"; do
    echo "$d -n standby,q -a -m $NOTIFY_EMAIL -I 5 -I 187 -I 197 -I 198 -M exec $ALERT_BIN"
  done
}

# replace our previously managed block, keep any hand-written lines
existing=""
if [ -f "$SMARTCTL_CFG" ]; then
  existing=$(grep -v '^# Managed by nasrpi' "$SMARTCTL_CFG" \
             | grep -v " -M exec $ALERT_BIN" || true)
fi
{ [ -n "$existing" ] && echo "$existing"; build_smartd; } | write_file 644 "$SMARTCTL_CFG" "sudo" "force" || true

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

# --- daily SMART status report --------------------------------------------------
# Use the same stable by-id paths as smartd and report the attributes watched
# above. smartctl -A output preserves vendor-specific raw values for review.
cat <<'EOF' | write_file 755 "$REPORT_BIN" "sudo" "force"
#!/bin/bash
set -u
TO=__NOTIFY_EMAIL__
BY_ID_DIR=__BY_ID_DIR__
SENDMAIL=/usr/sbin/sendmail
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

{
  echo "nasrpi daily SMART status — $(date '+%F')"
  echo
  shopt -s nullglob
  found=0
  for link in "$BY_ID_DIR"/*; do
    [ -L "$link" ] || continue
    dev=$(readlink -f "$link")
    [[ $dev =~ ^/dev/sd[a-z]+$ ]] || continue
    # Only report one by-id name for each physical device, as in setup.
    case " ${seen:-} " in *" $dev "*) continue ;; esac
    seen="${seen:-} $dev"
    found=1
    echo "===== $(basename "$link") ($dev) ====="
    if ! smartctl -a "$link"; then
      echo "WARNING: smartctl returned an error for $link"
    fi
    echo
  done
  [ "$found" -eq 1 ] || echo "No monitored ATA disks found under $BY_ID_DIR."
} > "$TMP" 2>&1
{
  echo "To: $TO"
  echo "Subject: nasrpi daily SMART status — $(date '+%F')"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo
  cat "$TMP"
} | "$SENDMAIL" -t
EOF
# Substitute configuration values into the installed script safely.
# (These values are administrator-provided local paths/address.)
# The quoted heredoc above keeps shell expansion for runtime, then sed embeds config.
# Re-write through a temporary generated copy to avoid placeholders in the script.
REPORT_TMP=$(mktemp)
sed -e "s|__NOTIFY_EMAIL__|$NOTIFY_EMAIL|g" \
    -e "s|__BY_ID_DIR__|$BY_ID_DIR|g" \
    "$(drify "$REPORT_BIN")" > "$REPORT_TMP"
write_file 755 "$REPORT_BIN" "sudo" "force" < "$REPORT_TMP"
rm -f "$REPORT_TMP"

ask SMART_REPORT_HOUR "Daily SMART report hour (0-23)" "7"
[[ "$SMART_REPORT_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || die "hour must be 0-23"
# Install directly: /etc/cron.d supports daily timing independent of weekly helpers.
install_cron nasrpi-smart-report "* $SMART_REPORT_HOUR 0" "/usr/local/bin/nasrpi-smart-report.sh"

say "03 done. Test with: echo test | sudo $ALERT_BIN /dev/sda"
