#!/usr/bin/env bash
# 06_setup_hd_idle.sh
# - make sure idle disks actually spin DOWN (03 only keeps SMART from waking them)
# - hd-idle rather than hdparm -S: every disk here sits in a USB/USB-SATA
#   enclosure, and those bridges usually ignore the ATA standby timer entirely.
#   hd-idle issues the SCSI START STOP UNIT that those bridges do understand.
# - one global idle timeout for all disks (default 30 min)
# - settings go into Debian's own /etc/default/hd-idle, which hd-idle.service
#   reads as its EnvironmentFile -- rerun this script to change the timeout.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

say "06 - hd-idle (spin down idle disks)"
apt_install hd-idle

HD_IDLE_CFG=/etc/default/hd-idle      # Debian's own config for the service
HD_IDLE_LOG=/var/log/hd-idle.log     # lives on the SD card: logging must not wake a disk
DRY_TARGET=$(drify "$HD_IDLE_CFG")

is_sd() { [[ $1 =~ ^sd[a-z]+$ ]]; }

# --- which disks are there -----------------------------------------------------
# hd-idle filters on the plain kernel name it sees in /proc/diskstats (sda, sdb),
# so collect whole sdX disks only (no partitions, no mmcblk/nvme/zram/dm).
DISKS=()
while read -r name type; do
  [ "$type" = disk ] && is_sd "$name" && DISKS+=("$name")
done < <(lsblk -rno NAME,TYPE 2>/dev/null || true)
if [ ${#DISKS[@]} -eq 0 ]; then
  warn "no /dev/sdX disks found -- nothing for hd-idle to spin down?"
else
  echo "  disks found: ${DISKS[*]}"
fi

# --- the disk holding / must never spin down -----------------------------------
ROOTDISK=""
if [ "${DRY_RUN:-0}" != "1" ]; then
  src=$(findmnt -no SOURCE --target / 2>/dev/null || true)      # e.g. /dev/mmcblk0p2
  if [ -n "$src" ]; then
    ROOTDISK=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
    [ -z "$ROOTDISK" ] && ROOTDISK=$(printf '%s' "${src##*/}" | sed -E 's/p?[0-9]+$//')
  fi
  if is_sd "$ROOTDISK"; then
    warn "root filesystem lives on $ROOTDISK: excluded from spin-down below"
  fi
fi

# --- settings ------------------------------------------------------------------
CUR_OPTS=""
[ -f "$DRY_TARGET" ] && CUR_OPTS=$(sed -n 's/^HD_IDLE_OPTS="\(.*\)"$/\1/p' "$DRY_TARGET" | head -1)
if [ -n "$CUR_OPTS" ]; then
  echo "  current: HD_IDLE_OPTS=\"$CUR_OPTS\""
  CUR_LOG=$(printf '%s' "$CUR_OPTS" | sed -n 's/.*-l \([^ ]*\).*/\1/p')
else
  CUR_LOG=""
fi
[ -n "$CUR_LOG" ] && HD_IDLE_LOG="$CUR_LOG"     # keep a hand-picked log location

ask SPIN_MIN "Spin a disk down after how many minutes without any I/O?" "30"
[[ "$SPIN_MIN" =~ ^[0-9]+$ ]] || die "please give a whole number of minutes"
SPIN_SECS=$((SPIN_MIN * 60))
if [ "$SPIN_SECS" -gt 0 ] && [ "$SPIN_SECS" -lt 300 ]; then
  warn "under 5 minutes means lots of spin-ups -- that wears disks out (floor is ~3-5 min)"
fi

# --- /etc/default/hd-idle --------------------------------------------------------
# hd-idle parses options left to right: -i before the first -a is the default for
# all disks; "-a <disk> -i 0" after it means "never spin that one down".
OPTS="-i $SPIN_SECS -l $HD_IDLE_LOG"
if [ -n "$ROOTDISK" ] && is_sd "$ROOTDISK"; then
  echo "  never spin down: $ROOTDISK"
  OPTS="$OPTS -a $ROOTDISK -i 0"
fi

tmp=$(mktemp)
cat > "$tmp" <<EOF
# Managed by nasrpi setup scripts (06) -- rerun 06_setup_hd_idle.sh to change.
START_HD_IDLE=true
HD_IDLE_OPTS="$OPTS"
EOF

changed=1
if [ -f "$DRY_TARGET" ] && cmp -s "$tmp" "$DRY_TARGET"; then
  ok "$HD_IDLE_CFG already spins disks down after ${SPIN_MIN} min"
  changed=0
else
  echo "  will write $HD_IDLE_CFG:"
  sed 's/^/    /' "$tmp"
  cat "$tmp" | write_file 644 "$HD_IDLE_CFG" "sudo" || changed=0   # declined -> don't restart
fi
rm -f "$tmp"

# --- make sure the daemon runs (and knows the new timeout) -----------------------
if [ "${DRY_RUN:-0}" = "1" ]; then
  warn "DRY_RUN: would enable hd-idle.service and (re)start it: hd-idle $OPTS"
else
  if [ "$(systemctl is-enabled hd-idle 2>/dev/null || true)" != enabled ]; then
    if confirm "Start hd-idle on boot (systemctl enable hd-idle)?"; then
      $NASRPI_SUDO systemctl enable hd-idle && ok "hd-idle enabled at boot"
    fi
  else
    ok "hd-idle enabled at boot"
  fi

  running=$(systemctl is-active hd-idle 2>/dev/null || true)
  if [ "$running" != active ]; then
    if confirm "Start the hd-idle daemon now?"; then
      $NASRPI_SUDO systemctl start hd-idle && ok "hd-idle started"
    fi
  elif [ "${changed:-0}" = 1 ]; then
    # hd-idle reads its idle times once at startup -- restart to apply them
    if confirm "Restart hd-idle so the new idle time takes effect?"; then
      $NASRPI_SUDO systemctl restart hd-idle && ok "hd-idle restarted"
    else
      warn "hd-idle keeps running with its OLD idle time until you restart it"
    fi
  else
    ok "hd-idle is running with these settings"
  fi

  echo "  running as: $(pgrep -a hd-idle 2>/dev/null | head -1 || echo 'not running')"
fi

say "06 done. Check with: sudo hdparm -C /dev/sda1 (state should become 'standby')
     watch spin-downs live:  tail -f $HD_IDLE_LOG
     spin one down right now: sudo hd-idle -t sda"
