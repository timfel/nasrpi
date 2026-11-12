#!/usr/bin/env bash

# Two backup cron jobs, both mailing a report through sendmail
#
#   media   rsync /media/media -> /media/media_backup, SMART on the disks behind them
#   nas     mbsync + rclone into /media/nas, rsync /media/nas -> /media/nas_backup,
#           SMART on the disks behind them (all of them: /media/nas_backup is a
#           mergerfs pool, so every disk in the pool gets a self-test)
#
# SMART: attributes 5, 187, 197 and 198 must stay at zero. If any of them is
# above zero the mail subject starts with ALERT ALERT ALERT and the mountpoint
# that the offending disk backs gets unmounted.

sudo apt install rsync smartmontools

# so it doesn't wake up usb disks all day
sudo systemctl disable --now smartmontools || true

cat <<'EOF' | sudo tee /usr/local/bin/nasrpi-backup.sh
#!/bin/bash
# nasrpi backup jobs. Installed by 04_backup_setup.sh; rerun 04 to change it.
#   nasrpi-backup.sh media   rsync /media/media -> /media/media_backup + SMART
#   nasrpi-backup.sh nas     mbsync + rclone + rsync /media/nas -> /media/nas_backup + SMART
# SMART runs on the disk(s) behind each mountpoint, so a mergerfs pool means one
# self-test per branch disk, one after another (a few minutes each).
set -u

# cron runs /etc/cron.d jobs with PATH=/usr/bin:/bin. sendmail is not there
# (msmtp-mta puts it in /usr/sbin) and /usr/local/bin is missing too, so
# anything installed by hand is invisible as well. The failure was quiet: the
# script's last line died with "sendmail: command not found", cron mailed that
# single line of stderr to root, and Gmail refused <root> as an address, so no
# report arrived at all. A sane PATH fixes the job.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

BAD_ATTRS="5 187 197 198"                 # raw values must stay at zero
DELETE_PCT=1                              # never delete more than this % of the destination

REPORT=$(mktemp)
BAD=$(mktemp)                             # one "mountpoint disk what" per line
trap 'rm -f "$REPORT" "$BAD"' EXIT

# this script mails its own report at the bottom, so it wants to leave nothing
# on stdout/stderr for cron to mail separately. Stray stderr (a tool complaining
# on its own, a typo in a line we did not redirect) belongs in the report, so
# that is where it goes instead of into a second, root-addressed mail.
exec 2>> "$REPORT"

say() { echo "$*" >> "$REPORT"; }

# a partition is the same physical disk as the whole device it sits on:
# /dev/sdb1 -> /dev/sdb, /dev/mmcblk0p1 -> /dev/mmcblk0
disk_of() {
    local src=$1 pk
    pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [ -n "$pk" ]; then echo "/dev/$pk"; else echo "$src"; fi
}

# what a mountpoint is mounted from, one line per branch: either a block device
# (/dev/sdb1) or a lower directory that is itself a mount (/media/laptop1t).
branches_under() {
    local want=$1 src pid
    # \040 is how /proc/mounts escapes a space in a path
    src=$(awk -v mp="$want" '{ s=$1; t=$2; gsub(/\\040/, " ", s); gsub(/\\040/, " ", t); if (t == mp) { print s; exit } }' /proc/mounts)
    case "$src" in
        /dev/*|/*) echo "$src"; return 0 ;;
    esac
    # a mergerfs pool gives no device away here: fsname=mergerfs replaces the
    # branch list in its /proc/mounts line. The running mount still knows it,
    # /proc/PID/cmdline reads "mergerfs <branches> <mountpoint> -o ...".
    for pid in $(pgrep -x mergerfs 2>/dev/null); do
        local -a argv=()
        mapfile -d '' argv < "/proc/$pid/cmdline" 2>/dev/null
        if [ "${argv[0]:-}" = mergerfs ] && [ "${argv[2]:-}" = "$want" ]; then
            printf '%s\n' "${argv[1]}" | tr ':' '\n'
            return 0
        fi
    done
    # last resort: the fstab entry, which configures the same pool
    awk -v mp="$want" '$1 !~ /^#/ && $2 == mp { print $1; exit }' /etc/fstab | tr ':' '\n'
}

# the block disks behind a mountpoint, whatever /dev/sdX they are today.
# /proc/mounts is the authority, so bind mounts count (/media/media is a bind
# of /media/mybook12t and still reports /dev/sdb1), and a mergerfs pool is
# followed down into its branch directories. The depth limit only exists to
# keep two mounts bound to each other from recursing forever.
disks_for() {
    local want=$1 depth=${2:-4} src
    [ "$depth" -gt 0 ] || return 0
    while read -r src; do
        [ -n "$src" ] || continue
        case "$src" in
            /dev/*) disk_of "$src" ;;
            /*)     [ "$src" = "$want" ] || disks_for "$src" $(( depth - 1 )) ;;
        esac
    done < <(branches_under "$want")
}

# start a short self-test and wait for it, so the status read below is current.
# A short test samples the platter instead of reading it, so it takes about two
# minutes whatever the size (12 TB included); ten minutes is the give-up cap.
selftest_short() {
    local dev=$1 waited=0 out running
    if ! smartctl -t short "$dev" >> "$REPORT" 2>&1; then
        say "    !!! could not start a short self-test"
        return 0
    fi
    while :; do
        sleep 15
        out=$(smartctl -l selftest "$dev" 2>&1)
        running=$(printf '%s\n' "$out" | grep -m1 'Self-test routine in progress' || true)
        [ -z "$running" ] && break
        waited=$(( waited + 15 ))
        [ "$waited" -ge 600 ] && { say "    self-test still running after 10 minutes"; break; }
    done
    say "    self-test finished after roughly $waited seconds:"
    printf '%s\n' "$out" | head -8 >> "$REPORT"
}

# SMART: self-test first, then the status read. Anything above zero lands in
# $BAD, which decides the subject and the unmount. Once something is bad the
# self-tests stop: the mail is an ALERT anyway, and a dying disk does not need
# another two minutes of reading itself.
smart() {
    local mp=$1 dev out a raw
    say "===== SMART: $mp ====="
    for dev in $(disks_for "$mp" | sort -u); do
        say "--- $dev"
        if [ -s "$BAD" ]; then
            say "    self-test skipped: something is already bad"
        else
            selftest_short "$dev"
        fi
        out=$(smartctl -a "$dev" 2>&1)
        for a in $BAD_ATTRS; do
            raw=$(printf '%s\n' "$out" | awk -v id="$a" '$1==id { print $NF; exit }')
            say "    attr $a: ${raw:-not reported}"
            case "$raw" in
                ''|*[!0-9]*) ;;
                *) [ "$raw" -gt 0 ] && echo "$mp $dev attr$a=$raw" >> "$BAD" ;;
            esac
        done
        if printf '%s\n' "$out" | grep -qi 'overall-health.*FAIL'; then
            echo "$mp $dev overall-health-FAILED" >> "$BAD"
        fi
    done
}

backup_pair() {   # src dest
    local src=$1 dest=$2
    if ! mountpoint -q "$src" || ! mountpoint -q "$dest"; then
        say "===== skipped $src -> $dest (both must be mounted) ====="
        return 0
    fi
    say "===== rsync $src -> $dest ====="
    # Dry run first: wiping more than DELETE_PCT of the destination means the
    # source is not what we think it is (dead disk, wrong or empty mount), so
    # report and leave the backup alone instead of mirroring the disaster.
    local dry del dest_files pct
    dry=$(rsync -an --delete --out-format='%n' "$src/" "$dest/" 2>/dev/null | grep '^deleting ' || true)
    del=$(printf '%s' "$dry" | grep -c . || true)
    dest_files=$(find "$dest" -type f 2>/dev/null | wc -l)
    pct=0
    [ "$dest_files" -gt 0 ] && pct=$(( del * 100 / dest_files ))
    if [ "$del" -gt 0 ] && [ "$pct" -gt "$DELETE_PCT" ]; then
        say "!!! SKIPPED: would delete $del of $dest_files files at $dest ($pct%), limit is $DELETE_PCT%"
        say "first 100 proposed deletions:"
        printf '%s\n' "$dry" | head -100 >> "$REPORT"
        skipped=1
        return 0
    fi
    say "proposed deletions: $del of $dest_files ($pct%), limit $DELETE_PCT%"
    # -i lists every file it touches, and that list IS the report.
    rsync -a -i --delete "$src/" "$dest/" >> "$REPORT" 2>&1 || say "!!! rsync $src -> $dest FAILED"
}

case "${1:-}" in
    media)
        backup_pair /media/media /media/media_backup
        smart /media/media
        smart /media/media_backup
        ;;
    nas)
        if mountpoint -q /media/nas; then
            say "===== mbsync ====="
            mbsync -c /etc/mbsyncrc -a >> "$REPORT" 2>&1 || say "!!! mbsync FAILED"
            say "===== rclone ====="
            for remote in $(rclone listremotes 2>/dev/null); do
                say "--- copy $remote -> /media/nas/rclone_${remote%:}"
                rclone copy "$remote" "/media/nas/rclone_${remote%:}" >> "$REPORT" 2>&1 \
                    || say "!!! rclone $remote FAILED"
            done
        else
            say "===== skipped mbsync and rclone: /media/nas is not mounted ====="
        fi
        backup_pair /media/nas /media/nas_backup
        smart /media/nas
        smart /media/nas_backup
        ;;
    *)
        echo "usage: $0 media|nas" >&2
        exit 2
        ;;
esac

subject="nasrpi $1 backup - $(date '+%F %H:%M')"
[ -n "${skipped:-}" ] && subject="SKIPPED $subject"
if [ -s "$BAD" ]; then
    subject="ALERT ALERT ALERT - $(cut -d' ' -f1 "$BAD" | sort -u | tr '\n' ' ') - $(date '+%F %H:%M')"
    # the disk giving up on us: stop using it rather than filling it further
    while read -r mp dev what; do
        say "!!! unmounting $mp ($dev: $what)"
        umount "$mp" 2>> "$REPORT" || timeout 30 umount -l "$mp" 2>> "$REPORT" || say "!!! could not unmount $mp"
    done < <(cut -d' ' -f1-2 "$BAD" | sort -u)
fi

{
    echo "To: timfelgentreff@gmail.com"
    echo "Subject: $subject"
    echo
    if [ -s "$BAD" ]; then
        echo "ALERT ALERT ALERT -- watched SMART attributes above zero:"
        cat "$BAD"
        echo
    fi
    cat "$REPORT"
} | sendmail -t          # -t: the To: header above decides the recipient; the
                        # envelope sender comes from /etc/msmtprc, not from cron
EOF
sudo chmod +x /usr/local/bin/nasrpi-backup.sh

cat <<'EOF' | sudo tee /etc/cron.d/nasrpi-backup
# the script mails its own report, so cron must not mail another one. Without
# this cron sends whatever the job leaves on stdout/stderr to the job owner
# (root), and Gmail answers 553 5.1.3 "<root> is not a valid RFC 5321 address".
MAILTO=""
0 10 * * 4   root  /usr/local/bin/nasrpi-backup.sh media
0 10 * * 3   root  /usr/local/bin/nasrpi-backup.sh nas
EOF
