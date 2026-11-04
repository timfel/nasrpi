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

# --- fake udev by-id tree (deterministic disks + id aliases for 03) ------------
# 03 scans <by-id>/ata* symlinks; point it at a sandbox tree of our own.
# Partitions, mmcblk/nvme targets and non-ata links must all be ignored,
# and the second alias of WDC40 must NOT create a second smartd entry.
export NASRPI_BY_ID_DIR="$T/by-id"
mkdir -p "$NASRPI_BY_ID_DIR"
ln -s /dev/sda  "$NASRPI_BY_ID_DIR/ata-WDC_WD40"
ln -s /dev/sda  "$NASRPI_BY_ID_DIR/ata-WDC_WD40_alias"   # duplicate id -> ignored
ln -s /dev/sdb  "$NASRPI_BY_ID_DIR/ata-Seagate_Seagate"
ln -s /dev/sdc  "$NASRPI_BY_ID_DIR/ata-Samsung_Samsung"
ln -s /dev/sdd  "$NASRPI_BY_ID_DIR/ata-Toshiba_Toshiba"
ln -s /dev/sda1 "$NASRPI_BY_ID_DIR/ata-WDC_WD40-part1"     # partition -> ignored
ln -s /dev/mmcblk0 "$NASRPI_BY_ID_DIR/ata-SD_Card"              # not sdX -> ignored
ln -s /dev/sdb1 "$NASRPI_BY_ID_DIR/usb-Seagate_usb"         # non-ata -> ignored

pass=0; fail=0
checknot() {  # checknot NAME REGEXP FILE -- pass when pattern is ABSENT
  if grep -qE -- "$2" "$3" 2>/dev/null; then
    echo "  FAIL: $1   (must not contain /$2/ in $3)"; fail=$((fail+1))
  else
    echo "  PASS: $1"; pass=$((pass+1))
  fi
}
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
check "fstab entry /media/media_backup"  "0sdb  /media/media_backup  ext4" "$F"
check "fstab entry /media/nas"           "0sdc  /media/nas  ext4"    "$F"
check "fstab entry /media/nas_backup"    "0sdd  /media/nas_backup  ext4" "$F"

echo "=== 01 rerun: idempotent"
sum_before=$(md5sum "$F")
runtest 01b '' ./01_establish_mount_points.sh
check "reports already set up" "already set up" "$T/01b.out"
[ "$sum_before" = "$(md5sum "$F")" ] \
  && { echo "  PASS: fstab untouched on rerun"; pass=$((pass+1)); } \
  || { echo "  FAIL: fstab changed on rerun"; fail=$((fail+1)); }

echo "=== 02 pizauth/mbsync/sendmail"
# Two accounts in pizauth's own config format. 02 keeps existing account blocks
# verbatim, so this fixture is what a previous run would have left behind.
mkdir -p "$R/etc"
cat > "$R/etc/pizauth.conf" <<'CONF'
# Managed by nasrpi setup scripts (02). Accounts: one 'account' block each.
# The text inside an existing account block is kept as-is when 02 reruns;
# global settings below come from /etc/default/nasrpi-pizauth.

# OAuth callback: only on loopback. Reach it from your laptop with
#   ssh -N -L 127.0.0.1:19024:127.0.0.1:19024 tim@thinkpad
http_listen = "localhost:19024";
startup_cmd = "/bin/sh /usr/local/bin/nasrpi-pizauth-restore";
token_event_cmd = "/bin/sh /usr/local/bin/nasrpi-pizauth-dump";
auth_notify_cmd = "/bin/sh /usr/local/bin/nasrpi-pizauth-notify auth";
error_notify_cmd = "/bin/sh /usr/local/bin/nasrpi-pizauth-notify error";

account "timfelgentreff_gmail_com" {
    client_id = "gmail-client-id";
    client_secret = "gmail-secret";
    auth_uri = "https://accounts.google.com/o/oauth2/auth";
    token_uri = "https://oauth2.googleapis.com/token";
    scopes = ["https://mail.google.com/"];
    auth_uri_fields = { "login_hint": "timfelgentreff@gmail.com" };
}

account "someone_outlook_com" {
    client_id = "outlook-client-id";
    client_secret = "outlook-secret";
    auth_uri = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
    token_uri = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
    scopes = ["https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send", "offline_access"];
    auth_uri_fields = { "login_hint": "someone@outlook.com" };
}
CONF
# blank gateway/ports (defaults), no new account, default mail settings for
# both accounts, cron Sunday 03:15, install it, sendmail uses account 1
runtest02_input='\n\n\n\nn\n\n\n\n\n0\n3\n15\ny\n1\n'
runtest 02 "$runtest02_input" ./02_setup_pizauth_mbsync_sendmail.sh
PZ="$R/etc/pizauth.conf"
PZDEF="$R/etc/default/nasrpi-pizauth"
check "both accounts seen"          "someone_outlook_com -> someone@outlook.com" "$T/02.out"
check "helpers: socket is pinned"  "XDG_RUNTIME_DIR" "$R/usr/local/bin/pizauth"
check "helpers: socket pinned to /run/pizauth" "XDG_RUNTIME_DIR:-/run/pizauth" "$R/usr/local/bin/pizauth"
check "key helper: derived from UDN"  "nasrpi-pizauth-v1|" "$R/usr/local/bin/nasrpi-pizauth-key"
check "dump helper seals"             "nasrpi-pizauth-key\" seal" "$R/usr/local/bin/nasrpi-pizauth-dump"
check "restore needs the LAN key"      "cannot open" "$R/usr/local/bin/nasrpi-pizauth-restore"
check "restore retries the socket"    "sleep 2" "$R/usr/local/bin/nasrpi-pizauth-restore"
check "defaults: gateway for the key" "GATEWAY=192.168.178.1"  "$PZDEF"
checknot "no dyndns in defaults"  "DYNDNS"                     "$PZDEF"
checknot "dump mode is not a choice" "DUMP_MODE"               "$PZDEF"
check "dump outside /media/nas"  "DUMP_FILE=/var/lib/pizauth/tokens.dump.gpg" "$PZDEF"
checknot "no UDN stored on disk"     "^UDN=."                 "$PZDEF"
checknot "no key material in defaults" "^[A-Z_]*KEY="         "$PZDEF"
check "conf: loopback callback is IPv4"  "http_listen = \"127.0.0.1:19024\";" "$R/etc/pizauth.conf"
checknot "conf: no hostname-based callback" "http_listen = \"localhost" "$R/etc/pizauth.conf"
check "conf: restore at boot"    'startup_cmd = "/bin/sh /usr/local/bin/nasrpi-pizauth-restore";' "$R/etc/pizauth.conf"
check "conf: dump on token events" 'token_event_cmd = "/bin/sh /usr/local/bin/nasrpi-pizauth-dump";' "$R/etc/pizauth.conf"
check "conf: gmail block kept"   "client_id = \"gmail-client-id\";" "$R/etc/pizauth.conf"
check "conf: outlook block kept" "client_id = \"outlook-client-id\";" "$R/etc/pizauth.conf"
check "unit: runs the server"    "ExecStart=/opt/pizauth/bin/pizauth server -c /etc/pizauth.conf -d" "$R/etc/systemd/system/pizauth.service"
check "unit: socket dir"         "RuntimeDirectory=pizauth"  "$R/etc/systemd/system/pizauth.service"
check "unit: env for root cron"  "Environment=XDG_RUNTIME_DIR=/run/pizauth" "$R/etc/systemd/system/pizauth.service"
check "unit: reload reloads conf" "ExecReload=/usr/local/bin/pizauth reload" "$R/etc/systemd/system/pizauth.service"
M="$R/etc/mbsyncrc"
check "mbsync: gmail account block"  "IMAPAccount timfelgentreff_gmail_com" "$R/etc/mbsyncrc"
check "mbsync: outlook account"     "IMAPAccount someone_outlook_com"   "$R/etc/mbsyncrc"
check "mbsync: gmail host"        "Host imap.gmail.com"            "$R/etc/mbsyncrc"
check "mbsync: outlook host"      "Host outlook.office365.com"      "$R/etc/mbsyncrc"
check "mbsync: xoauth2 to provider" "AuthMechs XOAUTH2"              "$R/etc/mbsyncrc"
check "mbsync: token from pizauth" "PassCmd \"/usr/local/bin/pizauth show timfelgentreff_gmail_com\"" "$R/etc/mbsyncrc"
check "mbsync: tls to provider"   "SSLType IMAPS"                   "$R/etc/mbsyncrc"
check "mbsync: far/near stores"   "Master :timfelgentreff_gmail_com-remote:" "$R/etc/mbsyncrc"
check "mbsync: near store"        "Slave :timfelgentreff_gmail_com-local:"  "$R/etc/mbsyncrc"
check "mbsync: subfolders verbatim" "SubFolders Verbatim"            "$R/etc/mbsyncrc"
check "mbsync: gmail All Mail only" "Patterns \"[Google Mail]/All Mail\"" "$R/etc/mbsyncrc"
check "mbsync: outlook all folders" "Patterns *"                 "$R/etc/mbsyncrc"
check "mbsync: sync state"        "SyncState *"                    "$R/etc/mbsyncrc"
check "mbsync: pull only"         "Sync Pull"                       "$R/etc/mbsyncrc"
check "mbsync: gmail folder"      "Path /media/nas/Mail/timfelgentreff_gmail_com/" "$R/etc/mbsyncrc"
checknot "mbsync: no proxy port"    "Port 1993"                      "$R/etc/mbsyncrc"
checknot "mbsync: no shared password" "^Pass "                       "$R/etc/mbsyncrc"
check "msmtp: xoauth2"            "auth xoauth2"                    "$R/etc/msmtprc"
check "msmtprc: gmail smtp host"  "host smtp.gmail.com"             "$R/etc/msmtprc"
check "msmtprc: outlook smtp host" "host smtp.office365.com"        "$R/etc/msmtprc"
check "msmtprc: token from pizauth" "passwordeval /usr/local/bin/pizauth show someone_outlook_com" "$R/etc/msmtprc"
check "msmtprc: starttls on 587"  "tls_starttls on"                 "$R/etc/msmtprc"
check "msmtprc: default is account 1" "account default : timfelgentreff_gmail_com" "$R/etc/msmtprc"
check "maps file lists both"      "someone_outlook_com.provider=outlook" "$R/etc/nasrpi-mailmaps"
check "mail cron installed"       "nasrpi-mail-sync.sh"             "$R/etc/cron.d/nasrpi-mail-sync"
check "mail cron schedule"        "15 3 * * 0 root"                 "$R/etc/cron.d/nasrpi-mail-sync"
check "mail sync waits for the NAS" "mountpoint -q /media/nas"       "$R/usr/local/bin/nasrpi-mail-sync.sh"
check "mail sync skips when pizauth is down" "not answering" "$R/usr/local/bin/nasrpi-mail-sync.sh"
checknot "mail sync never waits/polls" '^for i in|sleep 2'      "$R/usr/local/bin/nasrpi-mail-sync.sh"
# nothing may still mention the python proxy we replaced
if grep -rIl emailproxy "$R" 2>/dev/null | grep -q .; then
  echo "  FAIL: generated files still mention emailproxy"
  grep -rIl emailproxy "$R" | sed 's/^/    /'; fail=$((fail+1))
else
  echo "  PASS: no emailproxy left in the generated tree"; pass=$((pass+1))
fi
# every generated shell helper must parse
for h in "$R"/usr/local/bin/pizauth "$R"/usr/local/bin/nasrpi-pizauth-* \
         "$R"/usr/local/bin/nasrpi-mail-sync.sh; do
  if ! sh -n "$h" 2>/dev/null; then
    echo "  FAIL: $(basename "$h") is not valid shell"; fail=$((fail+1))
  fi
done
echo "  PASS: all generated helpers parse"; pass=$((pass+1))
# real parsers, when available
if command -v mbsync >/dev/null 2>&1; then
  if mbsync -c "$R/etc/mbsyncrc" -n -a 2>&1 | grep -qiE "not recognized|malformed|bad "; then
    echo "  FAIL: mbsync rejects the generated config"; fail=$((fail+1))
  else
    echo "  PASS: generated mbsyncrc parses (isync)"; pass=$((pass+1))
  fi
fi
if command -v msmtp >/dev/null 2>&1; then
  if msmtp --conflict=quit --conf-file="$R/etc/msmtprc" --serverinfo 2>&1 | grep -qiE "unknown|unknown"; then
    echo "  FAIL: msmtp rejects the generated config"; fail=$((fail+1))
  else
    echo "  PASS: generated msmtprc parses (msmtp)"; pass=$((pass+1))
  fi
fi

echo "=== 02 rerun: idempotent, no re-prompts"
conf_before=$(md5sum "$R/etc/pizauth.conf")
sum_before=$(md5sum "$R/etc/mbsyncrc")
runtest 02b '' ./02_setup_pizauth_mbsync_sendmail.sh
[ "$sum_before" = "$(md5sum "$R/etc/mbsyncrc")" ] \
  && { echo "  PASS: mbsyncrc stable on rerun"; pass=$((pass+1)); } \
  || { echo "  FAIL: mbsyncrc changed on rerun"; fail=$((fail+1)); }
[ "$conf_before" = "$(md5sum "$R/etc/pizauth.conf")" ] \
  && { echo "  PASS: pizauth.conf stable on rerun"; pass=$((pass+1)); } \
  || { echo "  FAIL: pizauth.conf changed on rerun"; fail=$((fail+1)); }
check "cron reported already correct" "already correct" "$T/02b.out"
check "mbsyncrc reported up to date"  "already up to date" "$T/02b.out"
checknot "rerun does not re-ask about storage" "Keep a token dump" "$T/02b.out"

echo "=== 03 smartmontools"
runtest 03 'alerts@example.com\ny\n' ./03_setup_smartmontools.sh
check "smartd monitors sda"       "$NASRPI_BY_ID_DIR/ata-WDC_WD40 -n standby,q -a -m alerts@example.com" "$R/etc/smartd.conf"
check "smartd covers all disks"    "$NASRPI_BY_ID_DIR/ata-Toshiba_Toshiba -n standby,q" "$R/etc/smartd.conf"
check "smartd leaves standby alone" "-n standby,q"                      "$R/etc/smartd.conf"
check "smartd watches attrs"       "-I 5 -I 187 -I 197 -I 198"         "$R/etc/smartd.conf"
check "smartd EXEC handler"        "-M exec /usr/local/bin/nasrpi-smartd-alert.sh" "$R/etc/smartd.conf"
checknot "no selftest schedule"     "-s "                               "$R/etc/smartd.conf"
check "handler takes device arg"   'DEV="${1:-$SMARTD_DEVICE}"'          "$R/usr/local/bin/nasrpi-smartd-alert.sh"
# one entry per disk: no partitions, no mmcblk/nvme, no duplicate id aliases
checknot "no partitions monitored"  "part1"                             "$R/etc/smartd.conf"
checknot "no mmcblk disks"         "mmcblk"                            "$R/etc/smartd.conf"
checknot "no nvme disks"           "nvme"                              "$R/etc/smartd.conf"
checknot "duplicate id alias dropped" "ata-WDC_WD40_alias"               "$R/etc/smartd.conf"
[ "$(grep -c 'ata-WDC_WD40 ' "$R/etc/smartd.conf")" -eq 1 ] \
  && { echo "  PASS: one smartd entry per disk"; pass=$((pass+1)); } \
  || { echo "  FAIL: duplicate disk entries in smartd.conf"; fail=$((fail+1)); }
check "handler auto-unmount on"   "AUTO_UNMOUNT=yes"                   "$R/usr/local/bin/nasrpi-smartd-alert.sh"
check "handler unmounts failures" "umount -R"                          "$R/usr/local/bin/nasrpi-smartd-alert.sh"
check "handler logs alerts"       "nasrpi-smart-alert.log"             "$R/usr/local/bin/nasrpi-smartd-alert.sh"
sh -n "$R/usr/local/bin/nasrpi-smartd-alert.sh" \
  && { echo "  PASS: alert handler syntax"; pass=$((pass+1)); } \
  || { echo "  FAIL: alert handler syntax"; fail=$((fail+1)); }

echo "=== 03 rerun: idempotent (force-replace must not eat answers)"
sdsum_before=$(md5sum "$R/etc/smartd.conf")
runtest 03r 'alerts@example.com\ny\n' ./03_setup_smartmontools.sh
[ "$sdsum_before" = "$(md5sum "$R/etc/smartd.conf")" ] \
  && { echo "  PASS: smartd.conf stable on rerun"; pass=$((pass+1)); } \
  || { echo "  FAIL: smartd.conf changed on rerun"; fail=$((fail+1)); }
check "smartd.conf reported up to date" "already up to date" "$T/03r.out"

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
check "media backup pair"         "/media/media /media/media_backup"   "$BK"
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
sed "s|^/media/nas /media/nas_backup\$|$T/fsrc $SB/dest|; s|^/media/media /media/media_backup\$|$SB/fmedia $SB/fbackup|; s|^LOG=.*|LOG=$SB/backup.log|" "$BK" > "$SB/run-backup.sh"

# scenario A: dest has 100 old files, src has 20 -> 100% deletions -> must SKIP + mail
# (the second, media pair runs alongside with identical dirs -> clean)
mkdir -p "$T/fsrc" "$SB/fmedia" "$SB/fbackup"
for i in $(seq 1 20);  do echo new > "$T/fsrc/file$i"; done
for i in $(seq 1 100); do echo old > "$SB/dest/old$i"; done
for i in $(seq 1 5);  do echo media > "$SB/fmedia/m$i"; cp "$SB/fmedia/m$i" "$SB/fbackup/"; done
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
if diff -r "$SB/fmedia" "$SB/fbackup" >/dev/null 2>&1; then
  echo "  PASS: media_backup mirrors media after backup"; pass=$((pass+1))
else
  echo "  FAIL: media_backup does not mirror media"; fail=$((fail+1))
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
   | PATH="$SB/bin:$PATH" sh "$SB/run-alert.sh" /dev/disk/by-id/ata-WDC_WD40 > "$T/03b.out" 2>&1; then
  echo "  PASS: alert handler exits 0"; pass=$((pass+1))
else
  echo "  FAIL: alert handler failed"; cat "$T/03b.out"; fail=$((fail+1))
fi
check "handler mailed unmount note" "UNMOUNTED /media/test"     "$T/mail.out"
check "handler mailed the report"   "SMART alert for /dev/disk/by-id/ata-WDC_WD40" "$T/mail.out"
check "handler called umount -R"    "umount -R /media/test"     "$SB/umount.log"

echo "=== cron files sanity"
for f in "$R"/etc/cron.d/nasrpi-*; do
  if grep -qE '^[0-9]{1,2} [0-9]{1,2} \* \* [0-6] root ' "$f"; then
    echo "  PASS: $(basename "$f") schedule line"; pass=$((pass+1))
  else
    echo "  FAIL: bad cron line in $f"; fail=$((fail+1))
  fi
done

echo "=== pizauth seal/unseal helpers (real gpg, unprivileged)"
if ./test_pizauth_seal.sh > "$T/seal.out" 2>&1; then
  echo "  PASS: LAN-sealed token dump works"; pass=$((pass+1))
  tail -2 "$T/seal.out" | sed 's/^/    /'
else
  echo "  FAIL: pizauth seal tests failed (full output: $T/seal.out)"; fail=$((fail+1))
  tail -20 "$T/seal.out" | sed 's/^/    /'
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$fail"
