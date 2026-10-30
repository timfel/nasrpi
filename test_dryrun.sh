#!/usr/bin/env bash
# test_dryrun.sh -- exercise all setup scripts WITHOUT touching the real system.
# Runs every script with DRY_RUN=1 against a shadow root under /tmp, with fake
# lsblk/blkid and canned answers. Catches syntax/logic errors and verifies the
# generated configs. Usage: ./test_dryrun.sh
set -u
cd "$(dirname "$0")"

T=$(mktemp -d /tmp/nasrpi-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
export DRY_RUN=1
export NASRPI_DRY_ROOT="$T/root"
export NASRPI_STATE="$T/state"
mkdir -p "$T/bin" "$NASRPI_DRY_ROOT"
R="$NASRPI_DRY_ROOT"          # all root-owned files land under here

# --- fake disk tooling (deterministic disks for 01/03) ------------------------
cat > "$T/bin/lsblk" <<'EOF'
#!/bin/sh
case "$*" in
  *NAME,SIZE,MODEL,FSTYPE*) printf '%s\n' "sda 4T WDC40" "sdb 8T Seagate" "sdc 4T Samsung" "sdd 8T Toshiba" ;;
  *NAME,TYPE*)              printf 'sda disk\nsdb disk\nsdc disk\nsdd disk\nzram0 zram\n' ;;
  *SIZE*)                   echo "4T" ;;
  *MODEL*)                  echo "FakeModel" ;;
  *MOUNTPOINT*)             echo "" ;;
  *)                        exit 0 ;;   # lsblk -n <dev> -> no children
esac
EOF
cat > "$T/bin/blkid" <<'EOF'
#!/bin/sh
# blkid -s UUID -o value <dev>: deterministic fake UUID per device
while [ $# -gt 1 ]; do shift; done
echo "00000000-0000-4000-8000-0000000000${1##*/}"
EOF
chmod +x "$T/bin/lsblk" "$T/bin/blkid"
export PATH="$T/bin:$PATH"

pass=0; fail=0
check() {  # check <desc> <fixed-string> <file>
  if grep -qF -- "$2" "$3" 2>/dev/null; then
    echo "  PASS: $1"; pass=$((pass+1))
  else
    echo "  FAIL: $1   (wanted '$2' in $3)"; fail=$((fail+1))
  fi
}
runtest() {  # runtest <name> <printf-answers> <script...>
  local name=$1 answers=$2; shift 2
  if printf "$answers" | "$@" > "$T/$name.out" 2>&1; then
    echo "  run OK: $name"; pass=$((pass+1))
  else
    echo "  RUN FAILED: $name"; sed 's/^/    /' "$T/$name.out"; fail=$((fail+1))
  fi
}

echo "=== 01 fresh fstab: guided assignment"
runtest 01 '1\ny\n1\ny\n1\ny\n1\ny\ny\n' ./01_establish_mount_points.sh
F="$R/etc/fstab"
check "fstab entry /media/media"         "0sda  /media/media  ext4"  "$F"
check "fstab entry /media/media_parity"  "0sdb  /media/media_parity  ext4" "$F"
check "fstab entry /media/nas"           "0sdc  /media/nas  ext4"    "$F"
check "fstab entry /media/nas_backup"    "0sdd  /media/nas_backup  ext4" "$F"

echo "=== 01 rerun: idempotent"
sum_before=$(md5sum "$F")
runtest 01b '' ./01_establish_mount_points.sh
check "reports already set up" "already set up" "$T/01b.out"
[ "$sum_before" = "$(md5sum "$F")" ] \
  && { echo "  PASS: fstab untouched on rerun"; pass=$((pass+1)); } \
  || { echo "  FAIL: fstab changed on rerun"; fail=$((fail+1)); }

echo "=== 02 emailproxy/mbsync/sendmail"
# answers: service y, add-accounts y, restart y, mailbox-names y, folder=demo,
#          dow=0 hour=3 min=15, cron-install y
runtest02_input='y\ny\ny\ny\ndemo\n0\n3\n15\ny\n\n'   # last line: msmtp password (empty = auth off)
runtest 02 "$runtest02_input" ./02_setup_emailproxy_mbsync_sendmail.sh
check "systemd unit created"        "ExecStart=/opt/emailproxy/bin/emailproxy --no-gui" "$R/etc/systemd/system/emailproxy.service"
check "mbsyncrc: account block"     "IMAPAccount demo_account" "$R/etc/mbsyncrc"
check "mbsyncrc: via emailproxy"    "Port 1143"                "$R/etc/mbsyncrc"
check "mbsyncrc: down only"         "Sync Pull"                      "$R/etc/mbsyncrc"
check "mbsyncrc: chosen mail folder" "/media/nas/Mail/demo/"         "$R/etc/mbsyncrc"
check "mail cron installed"         "nasrpi-mail-sync.sh"      "$R/etc/cron.d/nasrpi-mail"
check "mail cron schedule"          "15 3 * * 0 root"          "$R/etc/cron.d/nasrpi-mail"
check "mail sync skips unmounted"   "mountpoint -q /media/nas" "$R/usr/local/bin/nasrpi-mail-sync.sh"
check "msmtprc: emailproxy account" "account emailproxy"          "$R/etc/msmtprc"
check "msmtprc: via emailproxy"     "port 1143"                    "$R/etc/msmtprc"
check "msmtprc: from account"       "from demo_account"          "$R/etc/msmtprc"
check "msmtprc: default account"    "account default : emailproxy" "$R/etc/msmtprc"

echo "=== 02 rerun: idempotent, no re-prompts"
sum_before=$(md5sum "$R/etc/mbsyncrc")
runtest 02b '' ./02_setup_emailproxy_mbsync_sendmail.sh
[ "$sum_before" = "$(md5sum "$R/etc/mbsyncrc")" ] \
  && { echo "  PASS: mbsyncrc stable on rerun"; pass=$((pass+1)); } \
  || { echo "  FAIL: mbsyncrc changed on rerun"; fail=$((fail+1)); }
check "cron reported already correct" "already correct" "$T/02b.out"
check "mbsyncrc reported up to date"  "already up to date" "$T/02b.out"

echo "=== 03 smartmontools"
runtest 03 'alerts@example.com\ny\n6\n2\n30\ny\n' ./03_setup_smartmontools.sh
check "smartd monitors sda"       "/dev/sda -n standby,q -a -m alerts@example.com" "$R/etc/smartd.conf"
check "smartd covers all disks"    "/dev/sdd -n standby,q -a"          "$R/etc/smartd.conf"
check "no spin-up for self-tests"  "-d maint"                          "$R/etc/smartd.conf"
check "smartd watches attrs"    "-I 5 -I 187 -I 197 -I 198"        "$R/etc/smartd.conf"
check "smart cron installed"      "nasrpi-smart-check.sh"      "$R/etc/cron.d/nasrpi-smart"
check "zero-tolerance attrs"      "FAIL_ATTRS="                        "$R/usr/local/bin/nasrpi-smart-check.sh"
check "zero-tolerance: reallocated" "Reallocated_Sector_Ct"              "$R/usr/local/bin/nasrpi-smart-check.sh"
check "zero-tolerance: pending"     "Current_Pending_Sector"             "$R/usr/local/bin/nasrpi-smart-check.sh"
check "checker unmounts failures" "umount -R"                          "$R/usr/local/bin/nasrpi-smart-check.sh"
check "checker mails via sendmail" "sendmail -t"                         "$R/usr/local/bin/nasrpi-smart-check.sh"
sh -n "$R/usr/local/bin/nasrpi-smart-check.sh" \
  && { echo "  PASS: smart checker syntax"; pass=$((pass+1)); } \
  || { echo "  FAIL: smart checker syntax"; fail=$((fail+1)); }

echo "=== 04 rclone"
runtest 04 'y\n\n2\n4\n0\ny\n' ./04_setup_rclone.sh
check "rclone cron installed"     "nasrpi-rclone-sync.sh"      "$R/etc/cron.d/nasrpi-rclone"
check "sync copies (no deletes)"  "rclone copy"                      "$R/usr/local/bin/nasrpi-rclone-sync.sh"
check "sync skips unmounted"      "mountpoint -q /media/nas"         "$R/usr/local/bin/nasrpi-rclone-sync.sh"
check "remote folder mapping"     "/media/nas/demo_remote"          "$R/usr/local/bin/nasrpi-rclone-sync.sh"
sh -n "$R/usr/local/bin/nasrpi-rclone-sync.sh" \
  && { echo "  PASS: rclone sync script syntax"; pass=$((pass+1)); } \
  || { echo "  FAIL: rclone sync script syntax"; fail=$((fail+1)); }

echo "=== 05 backup"
runtest 05 'alerts@example.com\n5\n1\n2\n30\ny\n' ./05_setup_backup.sh
BK="$R/usr/local/bin/nasrpi-backup.sh"
check "backup cron installed"     "nasrpi-backup.sh"           "$R/etc/cron.d/nasrpi-backup"
check "backup cron schedule"      "30 2 * * 1 root"            "$R/etc/cron.d/nasrpi-backup"
check "delete limit carried over" "DELETE_PCT=\"5\""            "$BK"
check "safety dry-run first"      "rsync -an"                  "$BK"
check "rsync delete mode"         "rsync -a --delete"          "$BK"
check "mails when skipping"       "SKIPPED"                    "$BK"
check "mails on failure"          "FAILED"                     "$BK"
bash -n "$BK" \
  && { echo "  PASS: backup script syntax"; pass=$((pass+1)); } \
  || { echo "  FAIL: backup script syntax"; fail=$((fail+1)); }

echo "=== 05b: actually RUN the generated backup script on sandbox dirs"
SB="$T/func"; mkdir -p "$SB/src" "$SB/dest" "$SB/bin"
cat > "$SB/bin/mountpoint" <<EOF
#!/bin/sh
exit \${FAKE_MOUNT_RC:-0}   # pretend everything is mounted (unless test says otherwise)
EOF
cat > "$SB/bin/snapraid" <<EOF
#!/bin/sh
case "\$*" in
  *scrub*) echo "Errors: \${FAKE_SCRUB_ERRORS:-0}"; exit \${FAKE_SCRUB_RC:-0} ;;
  *)       echo "fake snapraid ok" ;;
esac
EOF
cat > "$SB/bin/sendmail" <<EOF
#!/bin/sh
cat >> "$T/mail.out"
EOF
chmod +x "$SB/bin/mountpoint" "$SB/bin/sendmail" "$SB/bin/snapraid"
cp "$BK" "$SB/run-backup.sh"
sed "s|^SRC=.*|SRC=$T/fsrc/|; s|^DEST=.*|DEST=$SB/dest/|; s|^LOG=.*|LOG=$SB/backup.log|" "$BK" > "$SB/run-backup.sh"

# scenario A: dest has 100 old files, src has 20 -> 100% deletions -> must SKIP + mail
mkdir -p "$T/fsrc"
for i in $(seq 1 20);  do echo new > "$T/fsrc/file$i"; done
for i in $(seq 1 100); do echo old > "$SB/dest/old$i"; done
if PATH="$SB/bin:$PATH" bash "$SB/run-backup.sh" > "$T/05a.out" 2>&1; then
  echo "  FAIL: should have skipped"; fail=$((fail+1))
else
  echo "  PASS: exited non-zero on mass-deletion"; pass=$((pass+1))
fi
check "safety mail sent (SKIPPED)" "SKIPPED" "$T/mail.out"
[ "$(ls "$SB/dest" | wc -l)" -eq 100 ] \
  && { echo "  PASS: dest untouched on skip"; pass=$((pass+1)); } \
  || { echo "  FAIL: dest was modified on skip"; fail=$((fail+1)); }

# scenario B: no pending deletions -> real rsync runs and mirrors src
rm -rf "$SB/dest"; mkdir -p "$SB/dest"
for i in $(seq 1 20); do echo new > "$SB/dest/file$i"; done
if PATH="$SB/bin:$PATH" bash "$SB/run-backup.sh" > "$T/05b.out" 2>&1; then
  echo "  PASS: clean backup run exits 0"; pass=$((pass+1))
else
  echo "  FAIL: clean backup run failed"; cat "$T/05b.out"; fail=$((fail+1))
fi
if diff -r "$T/fsrc" "$SB/dest" >/dev/null 2>&1; then
  echo "  PASS: dest mirrors src after backup"; pass=$((pass+1))
else
  echo "  FAIL: dest does not mirror src"; fail=$((fail+1))
fi

echo "=== 06 snapraid"
export NASRPI_MEDIA_DIR="$T/media" NASRPI_PARITY_DIR="$T/parity"
mkdir -p "$T/media/photos" "$T/media/music" "$T/parity"
runtest 06 'alerts@example.com\n\n\nn\n3\n5\n30\ny\n' ./06_setup_snapraid.sh
SNAP="$R/usr/local/bin/nasrpi-snapraid.sh"
check "snapraid conf: parity file"  "parity $T/parity/snapraid.parity" "$R/etc/snapraid.conf"
check "snapraid conf: data dir"     "data $T/media"                    "$R/etc/snapraid.conf"
check "snapraid conf: add music"    "add music $T/media/music"         "$R/etc/snapraid.conf"
check "snapraid conf: add photos"   "add photos $T/media/photos"       "$R/etc/snapraid.conf"
check "snapraid conf: content copies" "content "                       "$R/etc/snapraid.conf"
check "snapraid cron installed"     "nasrpi-snapraid.sh"               "$R/etc/cron.d/nasrpi-snapraid"
bash -n "$SNAP" \
  && { echo "  PASS: snapraid cron script syntax"; pass=$((pass+1)); } \
  || { echo "  FAIL: snapraid cron script syntax"; fail=$((fail+1)); }

echo "=== 06b: actually RUN the generated snapraid cron script"
sed "s|^LOG=.*|LOG=$SB/snapraid.log|; s|^CONF=.*|CONF=$R/etc/snapraid.conf|" "$SNAP" > "$SB/run-snapraid.sh"
mail_before=$(wc -c < "$T/mail.out" 2>/dev/null || echo 0)
# clean run: mounts ok (fake mountpoint), snapraid reports Errors: 0 -> no mail
if PATH="$SB/bin:$PATH" bash "$SB/run-snapraid.sh" > "$T/06a.out" 2>&1; then
  echo "  PASS: clean snapraid run exits 0"; pass=$((pass+1))
else
  echo "  FAIL: clean snapraid run failed"; cat "$T/06a.out"; fail=$((fail+1))
fi
mail_after=$(wc -c < "$T/mail.out" 2>/dev/null || echo 0)
[ "$mail_before" = "$mail_after" ] \
  && { echo "  PASS: no mail on clean run"; pass=$((pass+1)); } \
  || { echo "  FAIL: unexpected mail on clean run"; fail=$((fail+1)); }
# scrub errors -> report mail must be sent and exit non-zero
if FAKE_SCRUB_ERRORS=5 PATH="$SB/bin:$PATH" bash "$SB/run-snapraid.sh" > "$T/06b.out" 2>&1; then
  echo "  FAIL: scrub errors should exit non-zero"; fail=$((fail+1))
else
  echo "  PASS: scrub errors exit non-zero"; pass=$((pass+1))
fi
check "scrub error report mailed" "snapraid weekly" "$T/mail.out"
# not mounted -> quiet skip, exit 0, no mail
if FAKE_MOUNT_RC=1 PATH="$SB/bin:$PATH" bash "$SB/run-snapraid.sh" > "$T/06c.out" 2>&1; then
  echo "  PASS: skips cleanly when not mounted"; pass=$((pass+1))
else
  echo "  FAIL: should skip with exit 0 when unmounted"; fail=$((fail+1))
fi

echo "=== cron files sanity"
for f in "$R"/etc/cron.d/nasrpi-*; do
  if grep -qE '^[0-9]{1,2} [0-9]{1,2} \* \* [0-6] root ' "$f"; then
    echo "  PASS: $(basename "$f") schedule line"; pass=$((pass+1))
  else
    echo "  FAIL: bad cron line in $f"; fail=$((fail+1))
  fi
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$fail"
