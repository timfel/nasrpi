#!/usr/bin/env bash
# 04_setup_rclone.sh
# - install rclone
# - interactive: configure any remotes you need (rclone config)
# - weekly cron syncing every configured remote into /media/nas/<REMOTENAME>
#   (skips when /media/nas is not mounted)
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

say "04 - rclone"
MAPS_FILE=$(drify "$NASRPI_ETC_DIR/nasrpi-rclone-maps")
SYNC_BIN=/usr/local/bin/nasrpi-rclone-sync.sh

# --- install --------------------------------------------------------------------
if [ "${DRY_RUN:-0}" = "1" ]; then
  ok "rclone (DRY_RUN: pretending it is installed)"
elif command -v rclone >/dev/null; then
  ok "rclone already installed ($(rclone version | head -1))"
elif confirm "Install rclone now?"; then
  apt_install rclone || curl -LsSf https://rclone.org/install.sh | $NASRPI_SUDO bash
else
  die "rclone is required for the rest of this script."
fi

# --- configure remotes -----------------------------------------------------------
# Remotes are configured for ROOT (sudo): the weekly cron job runs as root and
# only sees root's rclone config.
if confirm "Configure rclone remotes now (runs sudo rclone config)?"; then
  echo "  rclone's own config wizard will start; add whatever remotes you need."
  echo "  (configured via sudo: the weekly sync cron runs as root and uses root's remotes)"
  [ "${DRY_RUN:-0}" != "1" ] && $NASRPI_SUDO rclone config
fi

REMOTES=()
if [ "${DRY_RUN:-0}" = "1" ]; then
  REMOTES=(demo_remote)                        # for testing the scripts only
else
  while read -r r; do [ -n "$r" ] && REMOTES+=("$r"); done < <($NASRPI_SUDO rclone listremotes)
fi
if [ "${#REMOTES[@]}" -eq 0 ]; then
  warn "No remotes configured. Add one (rerun this script), then rerun again."
  exit 0
fi
say "Remotes found: ${REMOTES[*]}"

# --- choose destination folders (asked once; rerun resets nothing) ---------------
folder_for() {
  local m=""
  [ -f "$MAPS_FILE" ] && m=$(grep -m1 "^$1=" "$MAPS_FILE" | cut -d= -f2-)
  echo "${m:-$(derive_name "$1")}"
}
if [ ! -f "$MAPS_FILE" ] && { [ "${DRY_RUN:-0}" != "1" ] || [ -n "${NASRPI_DRY_ROOT:-}" ]; }; then
  tmp=$(mktemp)                        # build in /tmp, move into place with sudo
  for r in "${REMOTES[@]}"; do
    d=$(derive_name "$r")
    read -r -p "  Folder under /media/nas for '$r' [${d}]: " custom || custom=""
    echo "${r}=${custom:-$d}" >> "$tmp"
  done
  $NASRPI_SUDO mkdir -p "$(dirname "$MAPS_FILE")"
  $NASRPI_SUDO mv "$tmp" "$MAPS_FILE"
  $NASRPI_SUDO chmod 644 "$MAPS_FILE"
  ok "saved folder mapping to $MAPS_FILE (edit that file any time)"
else
  ok "folder mapping at $MAPS_FILE exists (edit that file any time)"
  cat "$MAPS_FILE"
fi

# --- sync script + weekly cron -----------------------------------------------------
{
  echo '#!/bin/sh'
  echo '# nasrpi: weekly rclone sync of each remote into /media/nas/<name>.'
  echo '# Managed by nasrpi setup scripts (04); rerun 04 to regenerate.'
  echo 'mountpoint -q /media/nas || exit 0     # skip when target not mounted'
  for r in "${REMOTES[@]}"; do
    folder=$(folder_for "$r")
    # rclone copy (not sync): copies new/changed files, never deletes at target.
    echo "rclone copy --ignore-checksum --skip-links --transfers 4 --log-append /var/log/nasrpi-rclone.log '$r' '/media/nas/$folder'"
  done
} | write_file 755 "$SYNC_BIN" "sudo" || true

ask_dow_hour RCLONE
install_cron nasrpi-rclone "$RCLONE_DOW $RCLONE_HOUR $RCLONE_MIN" "$SYNC_BIN"

say "04 done. Test with: sudo $SYNC_BIN   (dry-run: rclone copy --dry-run ...)"
