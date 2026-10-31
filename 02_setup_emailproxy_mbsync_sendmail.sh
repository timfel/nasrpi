#!/usr/bin/env bash
# 02_setup_emailproxy_mbsync_sendmail.sh
# - install uv (system-wide) and emailproxy (under /opt/emailproxy)
# - systemd service: emailproxy --no-gui at boot, using OUR config file
# - interactive: add your mail accounts to emailproxy's config file.
#   $EP_ACCOUNTS uses emailproxy's own config format (emailproxy.config):
#     [IMAP-1993] / [SMTP-1587]               -> local listener + upstream server
#     [you@example.com]                       -> one section per mail account
#   Everything below is driven by that file: accounts and local ports.
# - OAuth sign-in: you run emailproxy --external-auth yourself in a second
#   shell; this script stops the service, triggers one IMAP login per account
#   (each login makes the proxy show its OAuth prompts in your other shell),
#   and restarts the service when you are done. Rerun 02 any time an account
#   needs (re)authentication.
# - mbsync pulling via emailproxy into /media/nas/Mail/<MAILBOX> (down only)
# - weekly cron for mbsync (skips when /media/nas is not mounted)
# - sendmail via msmtp + msmtp-mta, relaying through emailproxy's SMTP port
#
# nasrpi only ever talks IMAP + SMTP to the proxy, plain text on localhost
# (the proxy does all upstream TLS itself) -- no local TLS, no POP.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

PPREFIX=/opt
PREFIX="$PPREFIX/emailproxy"
EP_BIN="$PREFIX/bin/emailproxy"
EP_ACCOUNTS="$PREFIX/accounts.ini"           # emailproxy's OWN config file
EP_ACCOUNTS_VIEW=$(drify "$EP_ACCOUNTS")     # where an existing one is read from
EP_TOOL="$PWD/02_emailproxy.py"              # ini reader + login-trigger helper
MBSYNCRC="$NASRPI_ETC_DIR/mbsyncrc"
MSMTPRC="$NASRPI_ETC_DIR/msmtprc"
MSMTPRC_VIEW=$(drify "$NASRPI_ETC_DIR/msmtprc")
MAPS_FILE=$(drify "$PREFIX/.nasrpi-mailmaps")   # our "account -> folder" mapping

# Fallbacks, used only if the config declares no [IMAP-n]/[SMTP-n] sections.
IMAP_HOST=127.0.0.1
SMTP_HOST=127.0.0.1
IMAP_PORT=1993
SMTP_PORT=1587

say "02 - emailproxy + mbsync + sendmail"

# --- python (to read emailproxy's ini config) ----------------------------------
EP_PY=""
find_python() {
  local cand
  for cand in python3 python3.13 python3.12 python3.11 python; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
      EP_PY=$(command -v "$cand"); return 0
    fi
  done
  return 1
}
if ! find_python; then
  apt_install python3
  find_python || die "python3 (>= 3.8) is required to read emailproxy's config file."
fi
ok "using $EP_PY for the emailproxy config helper"

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
ExecStart=$EP_BIN --no-gui --config-file $EP_ACCOUNTS
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  if [ "${DRY_RUN:-0}" != "1" ]; then
    $NASRPI_SUDO systemctl daemon-reload
    $NASRPI_SUDO systemctl enable --now emailproxy.service
    ok "emailproxy.service enabled"
  fi
fi

# --- emailproxy's config file (your accounts live here) ------------------------
if [ ! -f "$EP_ACCOUNTS_VIEW" ]; then
  echo "  Creating $EP_ACCOUNTS (emailproxy's own config format)."
  "$EP_PY" "$EP_TOOL" template | write_file 600 "$EP_ACCOUNTS" "sudo" || warn "kept existing config"
  if [ "${DRY_RUN:-0}" != "1" ]; then
    echo "  Add your Gmail / Outlook / whatever accounts to $EP_ACCOUNTS."
    echo "  Each account needs: permission_url, token_url, oauth2_scope, client_id"
    echo "  (commented Outlook + Gmail examples are in that file)."
    sleep 2
    edit_file "$EP_ACCOUNTS" "sudo"
  fi
else
  ok "$EP_ACCOUNTS exists -- edit it directly any time, then rerun 02"
fi

# --- read that config file -----------------------------------------------------
# Accounts = sections whose heading is an e-mail address and that have a token_url;
# local ports come from the [IMAP-1993] / [SMTP-1587] style server sections.
EP_ERR=$(mktemp)
ep_rc=0
ACCOUNTS=()
# --all: also REPORT the shipped sample/placeholder sections (they stay ignored)
ACCOUNTS_OUT=$("$EP_PY" "$EP_TOOL" accounts "$EP_ACCOUNTS_VIEW" --all 2>"$EP_ERR") || ep_rc=$?
if [ -s "$EP_ERR" ]; then
  while IFS= read -r line; do warn "${line#\# }"; done < "$EP_ERR"
fi
case "$ep_rc" in
  0) while IFS= read -r acct_line; do
       if [ -n "$acct_line" ]; then ACCOUNTS+=("$acct_line"); fi
     done <<<"$ACCOUNTS_OUT" ;;
  3) warn "No configured accounts in $EP_ACCOUNTS (sample/placeholder entries are ignored)." ;;
  *) warn "Could not read $EP_ACCOUNTS." ;;
esac
if [ "${DRY_RUN:-0}" = "1" ] && [ "${#ACCOUNTS[@]}" -eq 0 ]; then
  ACCOUNTS=(demo_account)                       # fixture for script testing only
  warn "DRY_RUN: using fake account demo_account"
fi
if [ "${#ACCOUNTS[@]}" -eq 0 ]; then
  warn "Add accounts to $EP_ACCOUNTS, then rerun this script to set up mbsync/sending."
  exit 0
fi
say "Mail accounts in emailproxy config: ${ACCOUNTS[*]}"

# --- local proxy endpoints, from the config's server sections ------------------
read_proxy_servers() {
  local proto port host
  while IFS=$'\t' read -r proto port host; do
    case "$proto" in
      IMAP) IMAP_PORT=$port; IMAP_HOST=$host ;;
      SMTP) SMTP_PORT=$port; SMTP_HOST=$host ;;
    esac
  done < <("$EP_PY" "$EP_TOOL" servers "$EP_ACCOUNTS_VIEW" 2>/dev/null || true)
}
read_proxy_servers
say "emailproxy local endpoints: IMAP $IMAP_HOST:$IMAP_PORT, SMTP $SMTP_HOST:$SMTP_PORT (plain text, localhost)"

# --- the local proxy login password --------------------------------------------
# The proxy authenticates upstream with OAuth 2.0; this password is only used
# locally (mbsync/msmtp -> proxy) and to encrypt the cached tokens, so a single
# shared value for all accounts keeps things simple. emailproxy refuses logins
# without a password, so this is mandatory.
EP_PASSWORD=""
if [ -f "$MSMTPRC_VIEW" ]; then
  EP_PASSWORD=$(grep -m1 '^password ' "$MSMTPRC_VIEW" 2>/dev/null | cut -d' ' -f2-) || true
fi
if [ -z "$EP_PASSWORD" ] || confirm "Proxy login password on record. Re-enter it?"; then
  echo "  Local emailproxy login password (any value; it protects cached tokens)."
  read -r -s -p "  Password: " EP_PASSWORD || EP_PASSWORD=""
  echo
fi
[ -n "$EP_PASSWORD" ] || die "emailproxy requires a local login password -- nothing entered."

# --- OAuth sign-in: you run emailproxy in a SECOND shell -----------------------
# emailproxy only shows its OAuth prompts in the terminal it owns, so this
# script never runs the proxy itself. It stops the service, tells you how to
# start the proxy in a second shell, then triggers one IMAP login per account:
# each login makes the proxy print its OAuth URL and prompt for the paste-back
# in YOUR other shell, where you do the browser flow. "Login accepted" == that
# account has a working token. Rerun 02 any time an account needs re-auth.
if [ "${DRY_RUN:-0}" = "1" ]; then
  warn "DRY_RUN: would stop emailproxy.service, tell you to run emailproxy"
  warn "DRY_RUN: --no-gui --external-auth in a second shell, wait for you, trigger"
  warn "DRY_RUN: one IMAP login per account, and restart the service when you are done."
elif confirm "Run the OAuth sign-in flow now? (needed for new or re-auth accounts; no if tokens already work)"; then
  warn "Stopping emailproxy.service -- the OAuth prompts need a terminal of their own."
  $NASRPI_SUDO systemctl stop emailproxy.service
  echo
  echo "  Open a SECOND shell and run the proxy there:"
  echo
  echo "      sudo $EP_BIN --no-gui --external-auth --config-file $EP_ACCOUNTS"
  echo
  echo "  Leave it running: all sign-in prompts appear in THAT shell."
  read -r -p "  Press Enter once emailproxy is running in the other shell... " _ || true
  sleep 3                                  # let the proxy bind its local ports

  for a in "${ACCOUNTS[@]}"; do
    say "Triggering login for $a -- do the sign-in in the OTHER shell if it asks"
    if "$EP_PY" "$EP_TOOL" imap-login --host "$IMAP_HOST" --port "$IMAP_PORT" \
         --user "$a" --password "$EP_PASSWORD"; then
      ok "$a: login accepted -- OAuth token in place"
    else
      warn "$a: login not accepted -- rerun 02 (or this flow) to retry"
    fi
  done

  echo
  read -r -p "  Finished? Ctrl-C the proxy in the other shell, then press Enter here... " _ || true
  if $NASRPI_SUDO systemctl start emailproxy.service 2>/dev/null; then
    ok "emailproxy.service restored"
  else
    warn "could not start emailproxy.service -- start it manually"
  fi
fi

# --- mbsync ----------------------------------------------------------------------
apt_install isync

# ask once where each account's mail should live under /media/nas/Mail/
default_folder() {  # tim.felgentreff@oracle.com -> oracle ; fallback: whole address
  local a=$1 d=${1##*@}
  d=${d%%.*}
  if printf '%s' "$d" | grep -qE '^[A-Za-z][A-Za-z0-9_-]*$'; then
    printf '%s\n' "$d"
  else
    printf '%s\n' "$a" | tr -c 'A-Za-z0-9_-' '_'
  fi
}

if [ ! -f "$MAPS_FILE" ]; then
  echo "  Where should each account's mail live under /media/nas/Mail/?"
  maps_tmp=$(mktemp)                    # writable anywhere; moved into place with sudo below
  for a in "${ACCOUNTS[@]}"; do
    d=$(default_folder "$a")
    n=$d; i=2
    while grep -q "=$n\$" "$maps_tmp" 2>/dev/null; do n="${d}-$i"; i=$((i+1)); done
    read -r -p "  Mail folder name for '$a' [${n}]: " custom || custom=""
    echo "${a}=${custom:-$n}" >> "$maps_tmp"
  done
  # unquoted $NASRPI_SUDO: empty when already root
  $NASRPI_SUDO mkdir -p "$(dirname "$MAPS_FILE")"
  $NASRPI_SUDO mv "$maps_tmp" "$MAPS_FILE"
  $NASRPI_SUDO chmod 644 "$MAPS_FILE"   # readable on later unprivileged reruns
  ok "saved folder mapping to $MAPS_FILE (edit that file any time)"
fi

folder_for() {  # stored folder name for an account, fresh default if unmapped
  local m=""
  [ -f "$MAPS_FILE" ] && m=$(grep -m1 -- "^$1=" "$MAPS_FILE" | cut -d= -f2-)
  echo "${m:-$(default_folder "$1")}"
}

build_mbsyncrc() {
  echo "# Managed by nasrpi setup scripts."
  echo "# Accounts live in emailproxy's config ($EP_ACCOUNTS); rerun 02 after changing them."
  local a name dest
  for a in "${ACCOUNTS[@]}"; do
    name=$(printf '%s' "$a" | tr -c 'A-Za-z0-9_-' '_')   # mbsync-safe name
    dest=$(folder_for "$a")
    cat <<EOF

# ---- $a (via emailproxy $IMAP_HOST:$IMAP_PORT) ----
IMAPAccount $name
Host $IMAP_HOST
Port $IMAP_PORT
User $a
# emailproxy's local login password (see 02); '*' would prompt -> cron would fail.
Pass $EP_PASSWORD
AuthMechs LOGIN
# Plain text to the proxy on localhost; the proxy does the upstream TLS itself.
SSLType None

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

# holds the local proxy password -> keep it root-only
if build_mbsyncrc | write_file 600 "$MBSYNCRC" "sudo"; then
  if [ "${DRY_RUN:-0}" != "1" ] && confirm "Run mbsync now to pull mail?"; then
    $NASRPI_SUDO mbsync -c "$MBSYNCRC" -a || warn "sync failed (is emailproxy running?)"
  fi
fi

# --- weekly mbsync cron (down only, skips when nas not mounted) -----------------
cat <<'EOF' | write_file 755 /usr/local/bin/nasrpi-mail-sync.sh "sudo"
#!/bin/sh
# nasrpi: weekly mail pull via emailproxy (down only).
mountpoint -q /media/nas || exit 0   # skip when target not mounted
exec /usr/bin/mbsync -c /etc/mbsyncrc -a
EOF
ask_dow_hour MAIL
install_cron nasrpi-mail "$MAIL_DOW $MAIL_HOUR $MAIL_MIN" \
  "/usr/local/bin/nasrpi-mail-sync.sh"

# --- sendmail: msmtp (+ msmtp-mta) relaying through emailproxy --------------------
say "sendmail: outgoing mail via msmtp -> emailproxy SMTP ($SMTP_HOST:$SMTP_PORT)"
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
build_msmtprc() {
  echo "# Managed by nasrpi setup scripts (02); rerun 02 to regenerate."
  echo "defaults"
  # Plain text to the proxy on localhost; the proxy TLS-wraps the real upstream.
  echo "tls off"
  echo
  echo "account emailproxy"
  echo "host $SMTP_HOST"
  echo "port $SMTP_PORT"
  echo "from $smtp_account"
  # emailproxy always requires a password (checked above).
  echo "auth on"
  echo "user $smtp_account"
  echo "password $EP_PASSWORD"
  echo
  echo "account default : emailproxy"
}
if [ ! -f "$MSMTPRC_VIEW" ] || confirm "Existing msmtp config found. Replace it?"; then
  build_msmtprc | write_file 600 "$MSMTPRC" "sudo" || warn "kept existing msmtp config"
fi
if [ "${DRY_RUN:-0}" != "1" ]; then
  # sanity check: does it actually talk to emailproxy?
  if confirm "Send a test mail to $smtp_account to verify?"; then
    if { echo "To: $smtp_account"; echo "Subject: nasrpi test mail"; echo; echo "test"; } \
         | $NASRPI_SUDO sendmail -t 2>/dev/null; then
      ok "sendmail (msmtp) relays through emailproxy as $smtp_account"
    else
      warn "test send failed -- check $MSMTPRC and that emailproxy is running"
    fi
  fi
fi

say "02 done."
