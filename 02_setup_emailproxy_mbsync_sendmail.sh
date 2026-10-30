#!/usr/bin/env bash
# 02_setup_emailproxy_mbsync_sendmail.sh
# - install uv (system-wide) and emailproxy (under /opt/emailproxy)
# - systemd service: emailproxy --no-gui at boot
# - interactive: add your mail accounts to emailproxy's config
# - when the account set changes: OAuth via emailproxy --external-auth
#   (service stopped, proxy in foreground, one account at a time:
#    self-send trigger -> surface OAuth URL -> paste redirect URL back)
# - mbsync pulling via emailproxy into /media/nas/Mail/<MAILBOX> (down only)
# - weekly cron for mbsync (skips when /media/nas is not mounted)
# - sendmail via msmtp + msmtp-mta, relaying through emailproxy's SMTP port
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

PPREFIX=/opt
PREFIX="$PPREFIX/emailproxy"
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
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin "$NASRPI_SUDO" -E sh
  fi
else
  die "uv is required for the rest of this script."
fi

# --- emailproxy ---------------------------------------------------------------
if [ -x "$EP_BIN" ] || [ "${DRY_RUN:-0}" = "1" ]; then
  ok "emailproxy installed/prepared at $EP_BIN"
elif confirm "Install emailproxy under $PREFIX?"; then
  if [ "${DRY_RUN:-0}" = "1" ]; then
    warn "DRY_RUN: would run: uv tool install emailproxy"
  else
    env UV_TOOL_DIR="$PPREFIX" "$NASRPI_SUDO" -E uv tool install emailproxy
  fi
else
  die "emailproxy is required for the rest of this script."
fi

# --- systemd service -----------------------------------------------------------
if [ -f /etc/systemd/system/emailproxy.service ]; then
  ok "systemd service emailproxy.service already exists"
elif confirm "Add systemd service 'emailproxy' (starts --no-gui at boot)?"; then
  cat <<EOF | write_file 644 /etc/systemd/system/emailproxy.service "sudo"
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
if run_once "edit emailproxy $EP_ACCOUNTS"; then
  echo "  Add your Gmail / Outlook / whatever accounts in the editor."
  echo "  (emailproxy's local IMAP/SMTP port defaults to 1143.)"
  sleep 5
  [ "${DRY_RUN:-0}" != "1" ] && edit_file "$EP_ACCOUNTS" "sudo"
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

# --- OAuth external authentication (whenever the account set changes) -------------
# With --external-auth, emailproxy prints an OAuth URL to its output when no
# valid token exists, then waits for the redirect URL to be pasted back on
# stdin. So: stop the systemd service, run emailproxy in the foreground
# (attached, output streamed), trigger one self-addressed send per account in
# the background, surface the URL for the browser, paste the token/redirect back.
EP_ACCTS_STATE="${NASRPI_STATE:-$HOME/.nasrpi-state}.emailproxy-accounts"

auth_trigger() {  # force upstream activity for account $1, to make emailproxy need a token
  # NOTE: if your accounts.ini defines local client passwords, msmtp must
  # authenticate -- add --password=... here or use /etc/msmtprc profiles.
  { echo "To: $1"; echo "Subject: nasrpi auth trigger"; echo; echo "trigger"; } \
    | msmtp --host 127.0.0.1 --port 1143 --from "$1" --user "$1" "$1"
}

EP_LINE=""
ep_read_until() {  # $1 = ERE pattern, $2 = timeout secs; streams proxy output meanwhile
  local pat=$1 end=$((SECONDS + $2)) rc=1
  local line
  while (( SECONDS < end )); do
    if IFS= read -r -t 1 -u "$EP_OUT_FD" line; then
      echo "  [emailproxy] $line"
      if printf '%s\n' "$line" | grep -qE "$pat"; then
        EP_LINE=$line; rc=0; break
      fi
    fi
  done
  return $rc
}

external_auth_flow() {  # $@ = accounts to (re)authenticate
  local acct pasted url
  say "OAuth external-authentication for: $*"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    warn "DRY_RUN: would stop the emailproxy service, run it with --external-auth"
    warn "DRY_RUN: in the foreground, self-send per account, surface the OAuth URL"
    warn "DRY_RUN: and forward your pasted redirect URL back to the proxy."
    return 0
  fi

  warn "emailproxy.service is stopped during this flow (foreground emailproxy owns stdin/stdout)"
  systemctl stop emailproxy.service

  # foreground proxy, attached: its output streams to us, its stdin we write to
  coproc EP { "$EP_BIN" --no-gui --external-auth 2>&1; }
  local EP_OUT_FD=${EP[0]}

  ep_read_until 'istening|roxying|arted' 30 \
    || warn "emailproxy did not report listening within 30s -- continuing anyway"

  for acct in "$@"; do
    say "Account: $acct -- triggering self-addressed test mail (background)..."
    ( sleep 2; auth_trigger "$acct" ) &   # if no token: proxy prints auth URL next
    url=""
    if ep_read_until 'https?://' 30; then
      url=$(printf '%s\n' "$EP_LINE" | grep -oE 'https?://[^[:space:]]+' | head -1)
      echo
      echo "  ==== authentication needed for $acct ===="
      echo "  1) open this URL in your browser:"
      echo
      echo "       $url"
      echo
      echo "  2) sign in; the browser ends on a redirect URL that will not load"
      echo "  3) copy the FULL final URL from the address bar and paste it here"
      IFS= read -r -p "  pasted URL (empty = skip): " pasted < /dev/tty
      if [ -n "$pasted" ]; then
        printf '%s\n' "$pasted" >&"${EP[1]}"
        ep_read_until 'uthentication (completed|complete|success)|okens? (acquired|refreshed)|received' 90 \
          || warn "no clear completion message for $acct -- check the streamed output above"
        ok "auth exchange completed for $acct"
      else
        warn "skipped $acct"
      fi
    else
      ok "no auth URL for $acct within 30s -- token still valid, nothing to do"
    fi
  done

  kill "$EP_PID" 2>/dev/null || true
  wait "$EP_PID" 2>/dev/null || true
  systemctl start emailproxy.service
  ok "emailproxy.service restored"
}

# run the flow only when the configured account set actually changed
EP_ACCTS_CUR=$(printf '%s\n' "${ACCOUNTS[@]}" | sort)
EP_ACCTS_PREV=""
[ -f "$EP_ACCTS_STATE" ] && EP_ACCTS_PREV=$(cat "$EP_ACCTS_STATE")
if [ "$EP_ACCTS_CUR" != "$EP_ACCTS_PREV" ]; then
  external_auth_flow "${ACCOUNTS[@]}"
  printf '%s\n' "$EP_ACCTS_CUR" > "$EP_ACCTS_STATE"
  ok "account set recorded ($EP_ACCTS_STATE) -- external-auth flow reruns only on change"
fi

# --- mbsync ----------------------------------------------------------------------
apt_install isync

# ask once where each account's mail should live under /media/nas/Mail/
if run_once "write mbsync-mailbox-names to $MAPS_FILE"; then
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
Expunge Slave
New Remote
CopyArrivalDate yes
EOF
  done
}

if build_mbsyncrc | write_file 644 "$MBSYNCRC"; then
  if [ "${DRY_RUN:-0}" != "1" ] && run_once "mbsync -c $MBSYNCRC"; then
    echo "  First sync (tokens acquired via the external-auth flow above)."
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

# --- sendmail: msmtp (+ msmtp-mta) relaying through emailproxy --------------------
say "sendmail: outgoing mail via msmtp -> emailproxy SMTP (localhost:1143)"
apt_install msmtp msmtp-mta   # msmtp-mta provides /usr/sbin/sendmail for all tools
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
# msmtp reads /etc/msmtprc system-wide (msmtp-mta wires it to sendmail).
# Note: a personal ~/.msmtprc would override this file -- avoid one for root.
MSMTPRC="$NASRPI_ETC_DIR/msmtprc"          # write_file() applies the dry-run shadow
MSMTPRC_VIEW=$(drify "$NASRPI_ETC_DIR/msmtprc")   # where an existing file would be
SMTP_PASS=""
if [ ! -f "$MSMTPRC_VIEW" ] || confirm "Existing msmtp config found. Re-enter SMTP password/auth?"; then
  read -r -p "  SMTP password for emailproxy (empty = no AUTH): " SMTP_PASS || SMTP_PASS=""
fi
build_msmtprc() {
  echo "# Managed by nasrpi setup scripts (02); rerun 02 to regenerate."
  echo "defaults"
  echo "tls off"
  echo
  echo "account emailproxy"
  echo "host 127.0.0.1"
  echo "port 1143"
  echo "from $smtp_account"
  if [ -n "$SMTP_PASS" ]; then
    echo "auth on"
    echo "user $smtp_account"
    echo "password $SMTP_PASS"
  else
    echo "auth off"
  fi
  echo
  echo "account default : emailproxy"
}
build_msmtprc | write_file 600 "$MSMTPRC" || warn "kept existing msmtp config"
if [ "${DRY_RUN:-0}" != "1" ]; then
  # sanity check: does it actually talk to emailproxy?
  if confirm "Send a test mail to $smtp_account to verify?"; then
    if { echo "To: $smtp_account"; echo "Subject: nasrpi test mail"; echo; echo "test"; } \
         | sendmail -t 2>/dev/null; then
      ok "sendmail (msmtp) relays through emailproxy as $smtp_account"
    else
      warn "test send failed -- check $MSMTPRC and that emailproxy is running"
    fi
  fi
fi

say "02 done."
