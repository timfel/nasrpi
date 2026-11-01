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
  *UUID*)                   dev=$(echo "$*" | awk '{print $NF}')
                            echo "11111111-0000-0000-0000-0000000000${dev##*/}" ;;
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
# A realistic emailproxy config in the real emailproxy.config format:
# [IMAP-n]/[SMTP-n] listeners, accounts as [addr] sections, plus the shipped
# sample placeholders (which must be ignored).
mkdir -p "$R/opt/emailproxy"
cat > "$R/opt/emailproxy/accounts.ini" <<'CFG'
[Email OAuth 2.0 Proxy configuration file]
documentation = This is a sample Email OAuth 2.0 Proxy configuration file.
	format = documented inline

[Server setup]
documentation = Local servers are specified as [IMAP-1993] etc.

[IMAP-1993]
documentation = *** note: this server works for Office 365 and personal Outlook ***
server_address = imap.gmail.com
server_port = 993
local_address = 127.0.0.1

[SMTP-1587]
server_address = smtp-mail.outlook.com
server_port = 587
server_starttls = True
local_address = 127.0.0.1

[Account setup]
documentation = Accounts are specified using your email address as the section heading.

[tim.felgentreff@oracle.com]
permission_url = https://login.microsoftonline.com/common/oauth2/v2.0/authorize
token_url = https://login.microsoftonline.com/common/oauth2/v2.0/token
oauth2_scope = https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access
redirect_uri = http://localhost
client_id = 9e5f94bc-e8a4-4e73-b8be-63364c29d753

[timfelgentreff@gmail.com]
permission_url = https://accounts.google.com/o/oauth2/auth
token_url = https://oauth2.googleapis.com/token
oauth2_scope = https://mail.google.com/
redirect_uri = http://localhost
client_id = 406964657835-aq8lmia8j95dhl1a2bvharmfk3t1hgqj.apps.googleusercontent.com

[your.email@fastmail.com]
permission_url = https://api.fastmail.com/oauth/authorize
token_url = https://api.fastmail.com/oauth/refresh
oauth2_scope = https://www.fastmail.com/dev/protocol-imap
client_id = *** your client id here ***

[emailproxy]
allow_catch_all_accounts = False
CFG
# answers: service y, proxy password (oauth flow: dry-run prints, real run asks),
#          folder defaults (2 accounts), dow=0 hour=3 min=15, cron-install y
runtest02_input='y\nlocalproxy_pw\n\n\n0\n3\n15\ny\n'
runtest 02 "$runtest02_input" ./02_setup_emailproxy_mbsync_sendmail.sh
check "systemd unit: our config file" "ExecStart=/opt/emailproxy/bin/emailproxy --no-gui --config-file /opt/emailproxy/accounts.ini" "$R/etc/systemd/system/emailproxy.service"
check "accounts found from ini"    "tim.felgentreff@oracle.com" "$T/02.out"
check "second account found"       "timfelgentreff@gmail.com"   "$T/02.out"
check "sample entries reported"    "sample placeholder"          "$T/02.out"
check "mbsyncrc: oracle account"   "IMAPAccount tim_felgentreff_oracle_com" "$R/etc/mbsyncrc"
check "mbsyncrc: gmail account"    "IMAPAccount timfelgentreff_gmail_com"   "$R/etc/mbsyncrc"
check "mbsyncrc: real user name"   "User tim.felgentreff@oracle.com"         "$R/etc/mbsyncrc"
check "mbsyncrc: proxy imap port"  "Port 1993"                          "$R/etc/mbsyncrc"
check "mbsyncrc: plain to proxy"   "SSLType None"                       "$R/etc/mbsyncrc"
check "mbsyncrc: proxy password"   "Pass localproxy_pw"                "$R/etc/mbsyncrc"
check "mbsyncrc: LOGIN auth"       "AuthMechs LOGIN"                    "$R/etc/mbsyncrc"
check "mbsyncrc: down only"        "Sync Pull"                          "$R/etc/mbsyncrc"
check "mbsyncrc: mail folder"      "/media/nas/Mail/oracle/"             "$R/etc/mbsyncrc"
check "mail cron installed"        "nasrpi-mail-sync.sh"                "$R/etc/cron.d/nasrpi-mail"
check "mail cron schedule"         "15 3 * * 0 root"                    "$R/etc/cron.d/nasrpi-mail"
check "mail sync skips unmounted"  "mountpoint -q /media/nas"            "$R/usr/local/bin/nasrpi-mail-sync.sh"
check "msmtprc: emailproxy account" "account emailproxy"                 "$R/etc/msmtprc"
check "msmtprc: proxy smtp port"   "port 1587"                           "$R/etc/msmtprc"
check "msmtprc: plain to proxy"    "tls off"                             "$R/etc/msmtprc"
check "msmtprc: from account"      "from tim.felgentreff@oracle.com"     "$R/etc/msmtprc"
check "msmtprc: proxy password"    "password localproxy_pw"              "$R/etc/msmtprc"
check "msmtprc: default account"   "account default : emailproxy"        "$R/etc/msmtprc"
check "oauth flow described"       "IMAP login per account"            "$T/02.out"
check "msmtprc: auth on"           "auth on"                             "$R/etc/msmtprc"

echo "=== 02 rerun: idempotent, no re-prompts"
sum_before=$(md5sum "$R/etc/mbsyncrc")
runtest 02b '' ./02_setup_emailproxy_mbsync_sendmail.sh
[ "$sum_before" = "$(md5sum "$R/etc/mbsyncrc")" ] \
  && { echo "  PASS: mbsyncrc stable on rerun"; pass=$((pass+1)); } \
  || { echo "  FAIL: mbsyncrc changed on rerun"; fail=$((fail+1)); }
check "cron reported already correct" "already correct" "$T/02b.out"
check "mbsyncrc reported up to date"  "already up to date" "$T/02b.out"

echo "=== 03 smartmontools"
runtest 03 'alerts@example.com\ny\n' ./03_setup_smartmontools.sh
check "smartd monitors sda"       "/dev/disk/by-uuid/11111111-0000-0000-0000-0000000000sda -n standby,q -a -m alerts@example.com" "$R/etc/smartd.conf"
check "smartd covers all disks"    "/dev/disk/by-uuid/11111111-0000-0000-0000-0000000000sdd" "$R/etc/smartd.conf"
check "no spin-up for self-tests"  "-d maint"                          "$R/etc/smartd.conf"
check "smartd watches attrs"       "-I 5 -I 187 -I 197 -I 198"         "$R/etc/smartd.conf"
check "smartd EXEC handler"        "-M exec /usr/local/bin/nasrpi-smartd-alert.sh" "$R/etc/smartd.conf"
check "smartd passes device to handler" '$DEVICE'                       "$R/etc/smartd.conf"
check "handler auto-unmount on"   "AUTO_UNMOUNT=yes"                   "$R/usr/local/bin/nasrpi-smartd-alert.sh"
check "handler unmounts failures" "umount -R"                          "$R/usr/local/bin/nasrpi-smartd-alert.sh"
check "handler logs alerts"       "nasrpi-smart-alert.log"             "$R/usr/local/bin/nasrpi-smartd-alert.sh"
sh -n "$R/usr/local/bin/nasrpi-smartd-alert.sh" \
  && { echo "  PASS: alert handler syntax"; pass=$((pass+1)); } \
  || { echo "  FAIL: alert handler syntax"; fail=$((fail+1)); }

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
check "nas backup pair"           "/media/nas /media/nas_backup"       "$BK"
check "media backup pair"         "/media/media /media/media_parity"   "$BK"
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
cat > "$SB/bin/sendmail" <<EOF
#!/bin/sh
cat >> "$T/mail.out"
EOF
chmod +x "$SB/bin/mountpoint" "$SB/bin/sendmail"
cp "$BK" "$SB/run-backup.sh"
sed "s|^/media/nas /media/nas_backup\$|$T/fsrc $SB/dest|; s|^/media/media /media/media_parity\$|$SB/fmedia $SB/fparity|; s|^LOG=.*|LOG=$SB/backup.log|" "$BK" > "$SB/run-backup.sh"

# scenario A: dest has 100 old files, src has 20 -> 100% deletions -> must SKIP + mail
# (the second, media pair runs alongside with identical dirs -> clean)
mkdir -p "$T/fsrc" "$SB/fmedia" "$SB/fparity"
for i in $(seq 1 20);  do echo new > "$T/fsrc/file$i"; done
for i in $(seq 1 100); do echo old > "$SB/dest/old$i"; done
for i in $(seq 1 5);  do echo media > "$SB/fmedia/m$i"; cp "$SB/fmedia/m$i" "$SB/fparity/"; done
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
if diff -r "$SB/fmedia" "$SB/fparity" >/dev/null 2>&1; then
  echo "  PASS: media_parity mirrors media after backup"; pass=$((pass+1))
else
  echo "  FAIL: media_parity does not mirror media"; fail=$((fail+1))
fi

echo "=== 03b: actually RUN the smartd alert handler"
cat > "$SB/bin/lsblk" <<'EOF'
#!/bin/sh
case "$*" in
  *MOUNTPOINT*) echo "/media/test" ;;   # pretend the failing disk is mounted here
  *) exit 0 ;;
esac
EOF
cat > "$SB/bin/umount" <<EOF
#!/bin/sh
echo "umount \$*" >> "$SB/umount.log"
EOF
chmod +x "$SB/bin/lsblk" "$SB/bin/umount"
sed "s|^LOG=.*|LOG=$SB/alert.log|" "$R/usr/local/bin/nasrpi-smartd-alert.sh" > "$SB/run-alert.sh"
if echo "simulated smartd alert mail body" \
   | PATH="$SB/bin:$PATH" sh "$SB/run-alert.sh" /dev/disk/by-uuid/fake > "$T/03b.out" 2>&1; then
  echo "  PASS: alert handler exits 0"; pass=$((pass+1))
else
  echo "  FAIL: alert handler failed"; cat "$T/03b.out"; fail=$((fail+1))
fi
check "handler mailed unmount note" "UNMOUNTED /media/test"     "$T/mail.out"
check "handler mailed the report"   "SMART alert for /dev/disk/by-uuid/fake" "$T/mail.out"
check "handler called umount -R"    "umount -R /media/test"     "$SB/umount.log"

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
