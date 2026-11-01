#!/usr/bin/env bash
# 05_setup_backup.sh
# Weekly cron: rsync backups of
#   /media/nas   -> /media/nas_backup
#   /media/media -> /media/media_backup
# For each pair:
# - skips when either side is not mounted
# - skips (and mails a report) when more than N% of dest files would be deleted
# - mails a report on failure
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

say "05 - backup /media/nas -> /media/nas_backup and /media/media -> /media/media_backup"
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
# nasrpi: weekly rsync backups (source/dest pairs listed in PAIRS below)
# Managed by nasrpi setup scripts (05); rerun 05 -- or edit the values below.
NOTIFY_EMAIL="$NOTIFY_EMAIL"
DELETE_PCT="$DELETE_PCT"
# one "source dest" pair per line (trailing slashes are added automatically):
PAIRS="
/media/nas /media/nas_backup
/media/media /media/media_backup
"
LOG=/var/log/nasrpi-backup.log

report() {   # usage: some_output | report "Subject"
  {
    echo "To: \$NOTIFY_EMAIL"
    echo "Subject: \$1"
    echo
    cat
  } | sendmail -t 2>/dev/null || cat
}

run_pair() {   # usage: run_pair SRC DEST -- returns 1 only on mass-deletion skip or failure
  local SRC="\$1/" DEST="\$2/"

# skip quietly unless both targets are really mounted
mountpoint -q "\$DEST" || { echo "\$(date): skipped, \$DEST not mounted"; return 0; }
mountpoint -q "\$SRC"  || { echo "\$(date): skipped, \$SRC not mounted";  return 0; }

echo "\$(date): backup \$SRC -> \$DEST starting" >> "\$LOG"

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
  } | report "nasrpi backup SKIPPED \$SRC -> \$DEST: \$pct% deletions proposed"
  echo "\$(date): SKIPPED \$SRC -> \$DEST, \$del_count deletions (\$pct%) > \$DELETE_PCT%" >> "\$LOG"
  return 1
fi

# Real run
if rsync -a --delete "\$SRC" "\$DEST" >> "\$LOG" 2>&1; then
  echo "\$(date): backup \$SRC -> \$DEST finished ok (\$del_count deletions, \$pct%)" >> "\$LOG"
else
  {
    echo "rsync backup \$SRC -> \$DEST FAILED."
    echo "Last 50 log lines:"
    tail -50 "\$LOG"
  } | report "nasrpi backup FAILED on \$(hostname): \$SRC -> \$DEST"
  return 1
fi
echo "\$(date): backup \$SRC -> \$DEST complete" >> "\$LOG"
}

rc_all=0
while read -r src dest; do
  [ -n "\$src" ] || continue
  run_pair "\$src" "\$dest" || rc_all=1
done <<< "\$PAIRS"
exit "\$rc_all"
EOF

write_file 755 "$BACKUP_BIN" "sudo" < "$tmp"
rm -f "$tmp"

install_cron nasrpi-backup "$BACKUP_DOW $BACKUP_HOUR $BACKUP_MIN" "$BACKUP_BIN"

say "05 done. Test with: sudo $BACKUP_BIN"
