#!/usr/bin/env bash
# 01_establish_mount_points.sh
# Ensure the four data disks are in /etc/fstab (by UUID) under
# /media/media, /media/media_parity, /media/nas, /media/nas_backup.
# Idempotent: existing mount points are only re-confirmed, never clobbered.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
NASRPI_FSTAB=$(drify "$NASRPI_FSTAB")

say "01 - Establish mount points"

declare -A assigned_to   # UUID -> mount point
declare -A wanted        # mount point -> UUID chosen this run
FSTAB=$(cat "$NASRPI_FSTAB" 2>/dev/null || echo "")
# --- What does fstab already provide? ---------------------------------------
for mp in "${NASRPI_MOUNTS[@]}"; do
  line=$(echo "$FSTAB" | grep -v '^[[:space:]]*#' | awk -v m="$mp" '$2==m {print; exit}')
  if [ -n "$line" ]; then
    uuid=$(echo "$line" | grep -oE 'UUID=[0-9A-Fa-f-]+' | head -1 || true)
    if [ -n "$uuid" ]; then
      assigned_to["$uuid"]="$mp"
      wanted["$mp"]="$uuid"
      ok "$mp already in fstab ($uuid)"
    else
      warn "$mp is in fstab but not by UUID -- leaving it alone (review manually)"
      wanted["$mp"]="KEEP"
    fi
  fi
done

# --- What disks do we have? ---------------------------------------------------
say "Available block devices"
if ! command -v lsblk >/dev/null; then
  apt_install util-linux
fi
DISK_LIST=$(lsblk -dpno NAME,SIZE,MODEL,FSTYPE | sort)
echo "$DISK_LIST" | sed 's/^/  /'
echo

# Candidate disks: whole disks, not mounted anywhere, no children
declare -A dev_uuid
CANDIDATES=()
while read -r name; do
  [ -n "$name" ] || continue
  if lsblk -n "$name" | awk 'NR>1{n=1} END{exit !n}'; then
    continue   # has partitions/children -> skip
  fi
  if lsblk -nro MOUNTPOINT "$name" | grep -q .; then
    continue   # something under it is mounted
  fi
  uuid=$(blkid -s UUID -o value "$name" 2>/dev/null || true)
  if [ -z "$uuid" ]; then
    warn "$name has no filesystem UUID -- skipping (format it first if needed)"
    continue
  fi
  [ -n "${assigned_to[$uuid]:-}" ] && continue   # already used in fstab
  dev_uuid["$name"]="$uuid"
  CANDIDATES+=("$name")
done < <(echo "$DISK_LIST" | awk '{print $1}')

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  say "No unassigned disks found."
fi

# --- Assign missing mount points ---------------------------------------------
new_lines=""
for mp in "${NASRPI_MOUNTS[@]}"; do
  [ -n "${wanted[$mp]:-}" ] && continue
  say "Which disk should mount at $mp ?"
  if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    warn "No candidate disks left. Skipping $mp -- rerun this script after attaching one."
    continue
  fi
  select dev in "${CANDIDATES[@]}" "SKIP $mp"; do
    if [ -z "$dev" ]; then
      [ -t 0 ] || { echo "  (no input available -- skipping)"; break; }
      echo "  Pick a number."; continue
    fi
    if [[ "$dev" == SKIP* ]]; then
      echo "  Skipped $mp."
      dev=""
    else
      uuid=${dev_uuid[$dev]}
      size=$(lsblk -dno SIZE "$dev")
      model=$(lsblk -dno MODEL "$dev" | xargs)
      line="UUID=$uuid  $mp  ext4  defaults,user,noatime,nofail  0  2"
      echo
      echo "  $dev ($size${model:+, $model}) ->"
      echo "    $line"
      if confirm "  Confirm this assignment?"; then
        wanted["$mp"]="$uuid"
        new_lines+="$line"$'\n'
        # remove from candidate pool
        idx=0
        for i in "${!CANDIDATES[@]}"; do
          [ "${CANDIDATES[$i]}" = "$dev" ] && idx=$i
        done
        unset 'CANDIDATES[idx]'
        CANDIDATES=("${CANDIDATES[@]}")
      else
        continue
      fi
    fi
    break
  done
done

# --- Preview and apply fstab changes ------------------------------------------
if [ -z "$new_lines" ]; then
  say "fstab is already set up -- nothing to change."
  exit 0
fi

say "Proposed additions to $NASRPI_FSTAB"
echo "$new_lines" | sed 's/^/  + /'
if ! confirm "Write these to $NASRPI_FSTAB?"; then
  die "Aborted -- fstab unchanged."
fi

if [ "${DRY_RUN:-0}" = "1" ] && [ -z "${NASRPI_DRY_ROOT:-}" ]; then
  warn "DRY_RUN: would backup and update $NASRPI_FSTAB"
else
  mkdir -p "$(dirname "$NASRPI_FSTAB")"
  if [ -f "$NASRPI_FSTAB" ]; then
    "$NASRPI_SUDO" cp "$NASRPI_FSTAB" "$NASRPI_FSTAB.nasrpi.bak.$(date +%Y%m%d%H%M%S)"
    ok "backup saved as $NASRPI_FSTAB.nasrpi.bak.*"
  fi
  echo "$new_lines" >> "$NASRPI_FSTAB"
  ok "fstab updated (backup saved next to it)"
  if [ "${DRY_RUN:-0}" != "1" ] && confirm "Create mount directories and mount now?"; then
    for mp in "${!wanted[@]}"; do
      [ "${wanted[$mp]}" = "KEEP" ] && continue
      mkdir -p "$mp"
      mountpoint -q "$mp" || mount "$mp" || warn "could not mount $mp now"
    done
  fi
fi

say "01 done."
