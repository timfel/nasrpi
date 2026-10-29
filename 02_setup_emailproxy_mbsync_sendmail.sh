#!/usr/bin/env bash
# 02_setup_emailproxy_mbsync_sendmail.sh
# - install uv (system-wide) and emailproxy (under /opt/emailproxy)
# - systemd service: emailproxy --no-gui at boot
# - interactive: add your mail accounts to emailproxy's config
# - mbsync pulling via emailproxy into /media/nas/Mail/<MAILBOX> (down only)
# - weekly cron for mbsync (skips when /media/nas is not mounted)
# - sendmail (postfix) relaying through emailproxy's SMTP port
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

PREFIX=/opt/emailproxy
EP_BIN="$PREFIX/bin/emailproxy"
EP_ACCOUNTS="$PREFIX/accounts.ini"
EP_CFG="$PREFIX/config.cfg"
MBSYNCRC="$NASRPI_ETC_DIR/mbsyncrc"
MAPS_FILE=$(drify "$PREFIX/.nasrpi-mailmaps")   # our "account -> folder" mapping

say "02 - emailproxy + mbsync + sendmail"

# --- uv -----------------------------------------------------------------------
if command -v uv >/dev/null; then
  ok "uv already installed ($(uv --version))"
elif confirm "uv is not installed. Install it system-wide now?"; then
  if [ "${DRY_RUN:-0}" = "1" ]; then
    warn "DRY_RUN: would install uv into /usr/local/bin"
  else
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
  fi
else
  die "uv is required for the rest of this script."
fi

# --- emailproxy ---------------------------------------------------------------
if [ -x "$EP_BIN" ] || [ "${DRY_RUN:-0}" = "1" ]; then
  ok "emailproxy installed/prepared at $EP_BIN"
elif confirm "Install emailproxy under $PREFIX?"; then
  if [ "${DRY_RUN:-0}" = "1" ]; then
    warn "DRY_RUN: would run: uv tool install --prefix $PREFIX emailproxy"
  else
    uv tool install --prefix "$PREFIX" emailproxy
  fi
else
  die "emailproxy is required for the rest of this script."
fi

# --- systemd service -----------------------------------------------------------
if [ -f /etc/systemd/system/emailproxy.service ]; then
  ok "systemd service emailproxy.service already exists"
elif confirm "Add systemd service 'emailproxy' (starts --no-gui at boot)?"; then
  cat <<EOF | write_file 644 /etc/systemd/system/emailproxy.service
# Managed by nasrpi setup scripts
[Unit]
Description=Email proxy (emailproxy, no GUI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$EP_BIN --no-gui
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  if [ "${DRY_RUN:-0}" != "1" ]; then
    systemctl daemon-reload
    systemctl enable --now emailproxy.service
    ok "emailproxy.service enabled"
  fi
fi

# --- let the user configure their accounts -------------------------------------
if [ "${DRY_RUN:-0}" != "1" ] && [ ! -f "$EP_ACCOUNTS" ] && [ -x "$EP_BIN" ]; then
  echo "  Starting emailproxy briefly so it can create its default config..."
  timeout 20 "$EP_BIN" --no-gui >/dev/null 2>&1 || true
fi
if run_once "emailproxy-accounts"; then
  echo "  Add your Gmail / Outlook / whatever accounts in the editor."
  echo "  (emailproxy's local IMAP/SMTP port defaults to 1143.)"
  [ "${DRY_RUN:-0}" != "1" ] && edit_file "$EP_ACCOUNTS"
  if confirm "Accounts added -- restart emailproxy now?"; then
    [ "${DRY_RUN:-0}" != "1" ] && systemctl restart emailproxy.service
  fi
fi

# --- discover configured upstream mailers ---------------------------------------
# accounts.ini looks like:  [some_name.imap] / [some_name.smtp]
list_accounts() {
  local f
  for f in "$EP_ACCOUNTS" "$EP_CFG"; do
    if [ -f "$f" ]; then
      grep -hoE '^\[[^][.]++\.(imap|smtp)\]' "$f" 2>/dev/null \
        | tr -d '[]' | sed -E 's/\.(imap|smtp)$//' | sort -u
      return 0
    fi
  done
  return 1
}
ACCOUNTS=()
if [ "${DRY_RUN:-0}" = "1" ]; then
  ACCOUNTS=(demo_account)                       # for testing the scripts only
else
  while read -r a; do [ -n "$a" ] && ACCOUNTS+=("$a"); done < <(list_accounts)
fi
if [ "${#ACCOUNTS[@]}" -eq 0 ]; then
  warn "No mail accounts found in emailproxy config yet."
  warn "Add them (rerun this script, edit $EP_ACCOUNTS), then rerun for mbsync."
  exit 0
fi
say "Mail accounts found in emailproxy: ${ACCOUNTS[*]}"

# --- mbsync ----------------------------------------------------------------------
apt_install isync

# ask once where each account's mail should live under /media/nas/Mail/
if run_once "mbsync-mailbox-names"; then
  mkdir -p "$(dirname "$MAPS_FILE")"
  : > "$MAPS_FILE.tmp"
  for a in "${ACCOUNTS[@]}"; do
    d=$(derive_name "$a")
    read -r -p "  Mail folder name for '$a' [${d}]: " custom || custom=""
    echo "${a}=${custom:-$d}" >> "$MAPS_FILE.tmp"
  done
  mkdir -p "$(dirname "$MAPS_FILE")" && mv "$MAPS_FILE.tmp" "$MAPS_FILE"
  ok "saved folder mapping to $MAPS_FILE (edit that file any time)"
fi

folder_for() {  # stored folder name for an account, fresh default if unmapped
  local m=""
  [ -f "$MAPS_FILE" ] && m=$(grep -m1 "^$1=" "$MAPS_FILE" | cut -d= -f2-)
  echo "${m:-$(derive_name "$1")}"
}

build_mbsyncrc() {
  echo "# Managed by nasrpi setup scripts."
  echo "# Accounts live in emailproxy's config; rerun 02 after changing them."
  local a name dest
  for a in "${ACCOUNTS[@]}"; do
    name=$(echo "$a" | tr ' ' _)          # mbsync names must not contain spaces
    dest=$(folder_for "$a")
    cat <<EOF

# ---- $a (via emailproxy) ----
IMAPAccount $name
Host 127.0.0.1
Port 1143
User $a
Pass *
SSLType STARTTLS

IMAPStore $name-remote
Account $name

MaildirStore $name-local
Path /media/nas/Mail/$dest/
Inbox /media/nas/Mail/$dest/INBOX
Type Maildir
Format Maildir

Channel $name
Master $name-remote
Slave $name-local
# Down only: pull new/changed mail, never push local changes upstream.
Sync Pull
New Remote
CopyArrivalDate yes
EOF
  done
}

if build_mbsyncrc | write_file 644 "$MBSYNCRC"; then
  if [ "${DRY_RUN:-0}" != "1" ] && run_once "mbsync-initial-sync"; then
    echo "  First sync: enter any passwords emailproxy asks for."
    mbsync -c "$MBSYNCRC" -a || warn "initial sync failed (is emailproxy running?)"
  fi
fi

# --- weekly mbsync cron (down only, skips when nas not mounted) -----------------
cat <<'EOF' | write_file 755 /usr/local/bin/nasrpi-mail-sync.sh
#!/bin/sh
# nasrpi: weekly mail pull via emailproxy (down only).
mountpoint -q /media/nas || exit 0   # skip when target not mounted
exec /usr/bin/mbsync -c /etc/mbsyncrc -a
EOF
ask_dow_hour MAIL
install_cron nasrpi-mail "$MAIL_DOW $MAIL_HOUR $MAIL_MIN" \
  "/usr/local/bin/nasrpi-mail-sync.sh"

# --- sendmail (postfix) relaying through emailproxy ------------------------------
say "sendmail: outgoing mail via emailproxy SMTP (localhost:1143)"
apt_install postfix
smtp_account=${ACCOUNTS[0]}
if [ "${#ACCOUNTS[@]}" -gt 1 ] && [ "${DRY_RUN:-0}" != "1" ]; then
  echo "  Which upstream mailer should sendmail use?"
  select a in "${ACCOUNTS[@]}"; do
    [ -n "$a" ] && { smtp_account="$a"; break; }
    [ -t 0 ] || { echo "  (no input -- using ${smtp_account})"; break; }
    echo "  Pick a number."
  done
else
  ok "using ${smtp_account} for outgoing mail"
fi
if [ "${DRY_RUN:-0}" = "1" ]; then
  warn "DRY_RUN: would set relayhost=[127.0.0.1]:1143 (as $smtp_account)"
else
  postconf -e "relayhost = [127.0.0.1]:1143"
  postconf -e "smtp_sasl_auth_enable = yes"
  postconf -e "smtp_sasl_password_maps = static:$smtp_account"
  postconf -e "smtp_sasl_security = noplaintext noanonymous"
  postconf -e "smtp_tls_security_level = none"
  systemctl restart postfix
  ok "postfix relaying through emailproxy as $smtp_account"
fi

say "02 done."
