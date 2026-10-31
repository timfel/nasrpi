#!/usr/bin/env bash
# 05_setup_backup.sh
# Weekly cron: rsync /media/nas -> /media/nas_backup
# - skips when either side is not mounted
# - skips (and mails a report) when more than N% of dest files would be deleted
# - mails a report on failure
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

say "05 - backup /media/nas -> /media/nas_backup"
apt_install rsync
# sendmail comes from msmtp-mta (installed by 02); warn if it is missing.
[ "${DRY_RUN:-0}" = "1" ] || command -v sendmail >/dev/null \
  || warn "no sendmail found -- run step 02 first, reports will be printed only"

ask NOTIFY_EMAIL "Address to receive backup reports" "root"
ask DELETE_PCT   "Abort backup if more than what % of dest files would be deleted?" "5"
ask_dow_hour BACKUP

BACKUP_BIN=/usr/local/bin/nasrpi-backup.sh

tmp=$(mktemp)
cat > "$tmp" <<EOF
#!/bin/bash
# nasrpi: weekly rsync backup /media/nas -> /media/nas_backup
# Managed by nasrpi setup scripts (05); rerun 05 -- or edit the values below.
NOTIFY_EMAIL="$NOTIFY_EMAIL"
DELETE_PCT="$DELETE_PCT"
SRC=/media/nas/
DEST=/media/nas_backup/
LOG=/var/log/nasrpi-backup.log

report() {   # usage: some_output | report "Subject"
  {
    echo "To: \$NOTIFY_EMAIL"
    echo "Subject: \$1"
    echo
    cat
  } | sendmail -t 2>/dev/null || cat
}

# skip quietly unless both targets are really mounted
mountpoint -q "\${DEST%/}" || { echo "\$(date): skipped, \$DEST not mounted"; exit 0; }
mountpoint -q "\${SRC%/}"  || { echo "\$(date): skipped, \$SRC not mounted";  exit 0; }

echo "\$(date): backup starting" >> "\$LOG"

# Safety check: dry-run first and count proposed deletions vs. files at dest.
dry=\$(rsync -an --out-format='%n' --delete "\$SRC" "\$DEST" 2>/dev/null)
deleting=\$(printf '%s\n' "\$dry" | grep '^deleting ' || true)
del_count=\$(printf '%s' "\$deleting" | grep -c . || true)
dest_count=\$(find "\$DEST" -type f 2>/dev/null | wc -l)
pct=0
[ "\$dest_count" -gt 0 ] && pct=\$(( del_count * 100 / dest_count )) || pct=0

if [ "\$del_count" -gt 0 ] && [ "\$pct" -gt "\$DELETE_PCT" ]; then
  {
    echo "Backup SKIPPED as a safety measure."
    echo "\$del_count files (\$pct% of \$dest_count dest files) would be deleted,"
    echo "which exceeds the \$DELETE_PCT% limit. Nothing was changed."
    echo
    echo "First proposed deletions (up to 100):"
    printf '%s\n' "\$deleting" | head -100
  } | report "nasrpi backup SKIPPED: \$pct% deletions proposed"
  echo "\$(date): SKIPPED, \$del_count deletions (\$pct%) > \$DELETE_PCT%" >> "\$LOG"
  exit 1
fi

# Real run
if rsync -a --delete "\$SRC" "\$DEST" >> "\$LOG" 2>&1; then
  echo "\$(date): backup finished ok (\$del_count deletions, \$pct%)" >> "\$LOG"
else
  {
    echo "rsync backup \$SRC -> \$DEST FAILED."
    echo "Last 50 log lines:"
    tail -50 "\$LOG"
  } | report "nasrpi backup FAILED on \$(hostname)"
  exit 1
fi
echo "\$(date): backup complete" >> "\$LOG"
EOF

write_file 755 "$BACKUP_BIN" "sudo" < "$tmp"
rm -f "$tmp"

install_cron nasrpi-backup "$BACKUP_DOW $BACKUP_HOUR $BACKUP_MIN" "$BACKUP_BIN"

say "05 done. Test with: sudo $BACKUP_BIN"
