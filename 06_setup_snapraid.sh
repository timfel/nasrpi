#!/usr/bin/env bash
# 06_setup_snapraid.sh
# - snapraid with content on /media/media and parity on /media/media_parity
# - guides you if the parity location is too small for the data
# - weekly cron: snapraid sync + scrub (skips when not mounted),
#   reports errors via sendmail
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

MEDIA_DIR="${NASRPI_MEDIA_DIR:-/media/media}"
PARITY_DIR="${NASRPI_PARITY_DIR:-/media/media_parity}"
CONF="$NASRPI_ETC_DIR/snapraid.conf"   # write_file handles the dry-run shadow
CRON_BIN=/usr/local/bin/nasrpi-snapraid.sh

say "06 - snapraid (content: $MEDIA_DIR, parity: $PARITY_DIR)"
apt_install snapraid
ask NOTIFY_EMAIL "Address to receive snapraid reports" "root"

build_conf() {   # uses PARITY_FILE
  echo "# Managed by nasrpi setup scripts (06); rerun 06 to regenerate."
  echo "parity $PARITY_FILE"
  # two content-file copies: one local (fast), one off-disk (safe)
  echo "content /root/.snapraid/snapraid.content.1"
  echo "content $PARITY_DIR/.snapraid/snapraid.content.2"
  echo "data $MEDIA_DIR"
  # protect EVERYTHING under the content disk, recursively
  echo "add media $MEDIA_DIR"
}

# --- config -----------------------------------------------------------------------
if [ -f "$CONF" ]; then
  ok "snapraid config already at $CONF -- leaving it alone (edit it directly)"
else
  say "Configuring snapraid"
  ask PARITY_FILE  "Parity file path" "$PARITY_DIR/snapraid.parity"

  # everything under $MEDIA_DIR is protected (single recursive "add")
  [ -d "$MEDIA_DIR" ] || warn "$MEDIA_DIR not mounted? config still generated"
  build_conf | write_file 644 "$CONF" "sudo" || die "not writing snapraid config"

  # --- guide me if the parity location is too small ------------------------------
  while :; do
    if [ "${DRY_RUN:-0}" = "1" ]; then
      warn "DRY_RUN: skipping snapraid size check"
      break
    fi
    if out=$($NASRPI_SUDO snapraid -c "$CONF" -n sync 2>&1); then
      ok "snapraid accepts this layout"
      break
    fi
    warn "snapraid rejected the config:"
    echo "$out" | sed 's/^/    /'
    echo "  Common cause: parity location too small for the data."
    if confirm "Choose a different parity location?"; then
      ask PARITY_FILE "New parity file path" "$PARITY_DIR/snapraid.parity"
      build_conf | write_file 644 "$CONF" "sudo" || break
    else
      warn "Keeping this config -- fix parity before the first sync!"
      break
    fi
  done

  # --- first parity build -----------------------------------------------------------
  if confirm "Build initial parity now? (can take many hours; no = do it manually later)"; then
    if [ "${DRY_RUN:-0}" != "1" ]; then
      $NASRPI_SUDO mkdir -p /root/.snapraid "$PARITY_DIR/.snapraid"
      $NASRPI_SUDO snapraid -c "$CONF" sync \
        || warn "initial sync failed -- fix, then run: sudo snapraid -c $CONF sync"
    fi
  fi
fi

# --- weekly sync + scrub cron ---------------------------------------------------------
cat <<EOF | write_file 755 "$CRON_BIN" "sudo"
#!/bin/bash
# nasrpi: weekly snapraid sync + scrub.
# Managed by nasrpi setup scripts (06); rerun 06 to regenerate.
MEDIA=$MEDIA_DIR
PARITY=$PARITY_DIR
CONF=$CONF
NOTIFY_EMAIL=$NOTIFY_EMAIL
LOG=/var/log/nasrpi-snapraid.log

report() {   # usage: some_output | report "Subject"
  {
    echo "To: \$NOTIFY_EMAIL"
    echo "Subject: \$1"
    echo
    cat
  } | sendmail -t 2>/dev/null || cat
}

mountpoint -q "\$MEDIA"  || exit 0   # skip when content not mounted
mountpoint -q "\$PARITY" || exit 0   # skip when parity not mounted
[ -f "\$CONF" ] || exit 0

echo "\$(date): snapraid sync starting" >> "\$LOG"
sync_out=\$(snapraid -c "\$CONF" sync 2>&1); rc_sync=\$?
echo "\$(date): sync rc=\$rc_sync" >> "\$LOG"

echo "\$(date): snapraid scrub starting" >> "\$LOG"
scrub_out=\$(snapraid -c "\$CONF" scrub 2>&1); rc_scrub=\$?
echo "\$(date): scrub rc=\$rc_scrub" >> "\$LOG"
echo "\$scrub_out" >> "\$LOG"

# scrub ends with a summary like "Errors: 0"; anything more is bad news
if [ "\$rc_sync" -ne 0 ] || [ "\$rc_scrub" -ne 0 ] \
   || printf '%s\n' "\$sync_out\$scrub_out" | grep -qiE 'Errors: [1-9]|FATAL|Aborted'; then
  {
    echo "snapraid weekly sync/scrub found problems."
    echo "--- sync output ---"
    echo "\$sync_out"
    echo "--- scrub output ---"
    echo "\$scrub_out"
  } | report "nasrpi snapraid ERRORS on \$(hostname)"
  exit 1
fi
echo "\$(date): snapraid ok" >> "\$LOG"
EOF

ask_dow_hour SNAPRAID
install_cron nasrpi-snapraid "$SNAPRAID_DOW $SNAPRAID_HOUR $SNAPRAID_MIN" "$CRON_BIN"

say "06 done. Check with: sudo snapraid -c /etc/snapraid.conf status"
