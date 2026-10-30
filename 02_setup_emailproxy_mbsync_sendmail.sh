#!/usr/bin/env bash
# 02_setup_emailproxy_mbsync_sendmail.sh
# - install uv (system-wide) and emailproxy (under /opt/emailproxy)
# - systemd service: emailproxy --no-gui at boot, using OUR config file
# - interactive: add your mail accounts to emailproxy's config file.
#   $EP_ACCOUNTS uses emailproxy's own config format (emailproxy.config):
#     [IMAP-1993] / [POP-1995] / [SMTP-1587]  -> local listener + upstream server
#     [you@example.com]                       -> one section per mail account
#   Everything below is driven by that file: accounts, local ports, TLS mode.
# - when the account set changes: OAuth via emailproxy --external-auth
#   (service stopped, proxy runs in the foreground and prompts you itself;
#    one IMAP login per account is triggered, accepted login == token acquired)
# - mbsync pulling via emailproxy into /media/nas/Mail/<MAILBOX> (down only)
# - weekly cron for mbsync (skips when /media/nas is not mounted)
# - sendmail via msmtp + msmtp-mta, relaying through emailproxy's SMTP port
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
IMAP_TLS=off
SMTP_TLS=off
EP_AUTH_TRIES=3          # login attempts per account during the OAuth flow

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
    systemctl daemon-reload
    systemctl enable --now emailproxy.service
    ok "emailproxy.service enabled"
  fi
fi

# --- emailproxy's config file (your accounts live here) ------------------------
if [ ! -f "$EP_ACCOUNTS_VIEW" ] || run_once "edit emailproxy accounts in $EP_ACCOUNTS"; then
  if [ ! -f "$EP_ACCOUNTS_VIEW" ]; then
    echo "  Creating $EP_ACCOUNTS (emailproxy's own config format)."
    "$EP_PY" "$EP_TOOL" template | write_file 600 "$EP_ACCOUNTS" "sudo" || warn "kept existing config"
  fi
  if [ "${DRY_RUN:-0}" != "1" ]; then
    echo "  Add your Gmail / Outlook / whatever accounts to $EP_ACCOUNTS."
    echo "  Each account needs: permission_url, token_url, oauth2_scope, client_id"
    echo "  (commented Outlook + Gmail examples are in that file)."
    sleep 2
    edit_file "$EP_ACCOUNTS" "sudo"
  fi
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

ep_catchall=$("$EP_PY" "$EP_TOOL" catchall "$EP_ACCOUNTS_VIEW" 2>/dev/null || echo False)
if [ "$ep_catchall" = "True" ]; then
  warn "allow_catch_all_accounts is on: accounts the proxy creates on the fly are not"
  warn "seen here -- rerun 02 after new accounts show up in $EP_ACCOUNTS."
fi

# --- local proxy endpoints, from the config's server sections ------------------
IMAP_PORT_SET=""; SMTP_PORT_SET=""; POP_PORT=""
read_proxy_servers() {
  local proto port host local_tls server_tls
  while IFS=$'\t' read -r proto port host local_tls server_tls; do
    case "$proto" in
      IMAP) if [ -z "$IMAP_PORT_SET" ]; then
              IMAP_PORT=$port; IMAP_HOST=$host; IMAP_TLS=$local_tls; IMAP_PORT_SET=1
            fi ;;
      SMTP) if [ -z "$SMTP_PORT_SET" ]; then
              SMTP_PORT=$port; SMTP_HOST=$host; SMTP_TLS=$local_tls; SMTP_PORT_SET=1
            fi ;;
      POP)  POP_PORT=$port ;;
    esac
  done < <("$EP_PY" "$EP_TOOL" servers "$EP_ACCOUNTS_VIEW" 2>/dev/null || true)
  if [ -n "$POP_PORT" ]; then
    warn "POP3 listener on $POP_PORT in the proxy config -- nasrpi syncs via IMAP only."
  fi
  if [ -z "$IMAP_PORT_SET" ]; then
    warn "No [IMAP-<port>] server in $EP_ACCOUNTS -- assuming $IMAP_HOST:$IMAP_PORT."
  fi
  if [ -z "$SMTP_PORT_SET" ]; then
    warn "No [SMTP-<port>] server in $EP_ACCOUNTS -- assuming $SMTP_HOST:$SMTP_PORT."
  fi
}
read_proxy_servers
say "emailproxy local endpoints: IMAP $IMAP_HOST:$IMAP_PORT (tls $IMAP_TLS), SMTP $SMTP_HOST:$SMTP_PORT (tls $SMTP_TLS)"
if [ "$IMAP_TLS" = "on" ] || [ "$SMTP_TLS" = "on" ]; then
  warn "local_starttls is enabled in the proxy config: mbsync/msmtp are set to STARTTLS"
  warn "-- make sure the proxy's local certificate is trusted by them."
fi

# --- the local proxy login password --------------------------------------------
# The proxy authenticates upstream with OAuth 2.0; this password is only used
# locally (mbsync/msmtp -> proxy) and to encrypt the cached tokens, so a single
# shared value for all accounts keeps things simple (see the sample config notes).
EP_PASSWORD=""
if [ -f "$MSMTPRC_VIEW" ]; then
  EP_PASSWORD=$(grep -m1 '^password ' "$MSMTPRC_VIEW" 2>/dev/null | cut -d' ' -f2-) || true
fi
if [ -z "$EP_PASSWORD" ] || confirm "Proxy login password on record. Re-enter it?"; then
  echo "  Local emailproxy login password (any value; it protects cached tokens)."
  read -r -s -p "  Password (empty = clients connect without AUTH): " EP_PASSWORD || EP_PASSWORD=""
  echo
fi

# --- OAuth external authentication (when the account set changes) --------------
# emailproxy only needs a token when a client logs in, and in
# `--no-gui --external-auth` mode it prints the OAuth URL and prompts for the
# post-authentication URL itself (which needs a real terminal). So: stop the
# service, run the proxy in the FOREGROUND attached to this terminal, trigger one
# IMAP login per account in the background, and treat "login accepted" (helper
# exit 0) as "this account has a working token".
EP_ACCTS_STATE="${NASRPI_STATE:-$HOME/.nasrpi-state}.emailproxy-accounts"
EP_LOG=""
ep_pid=""

auth_trigger() {  # $1 = account; exit 0 once emailproxy accepts the login
  "$EP_PY" "$EP_TOOL" imap-login --host "$IMAP_HOST" --port "$IMAP_PORT" \
    --user "$1" --password "$EP_PASSWORD"
}

show_auth_url() {  # $1 = account: highlight the OAuth URL once the proxy logs it
  local acct=$1 end=$((SECONDS + 25)) url
  while (( SECONDS < end )); do
    url=$(grep -F "to authenticate account $acct:" "$EP_LOG" 2>/dev/null \
            | grep -oE 'https?://[^[:space:]]+' | tail -1)
    if [ -n "$url" ]; then
      echo
      echo "  ==== $acct: sign in at this URL (emailproxy shows it above too) ===="
      echo "       $url"
      echo "  ...then paste the final (non-loading) browser URL into emailproxy's prompt."
      return 0
    fi
    sleep 1
  done
  return 1
}

ep_stop_service() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  warn "Stopping emailproxy.service (the foreground proxy needs this terminal)"
  systemctl stop emailproxy.service
}

ep_restore_service() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  if [ -n "$ep_pid" ]; then
    kill "$ep_pid" 2>/dev/null || true
    wait "$ep_pid" 2>/dev/null || true
    ep_pid=""
  fi
  if systemctl start emailproxy.service 2>/dev/null; then
    ok "emailproxy.service restored"
  else
    warn "could not start emailproxy.service -- start it manually"
  fi
}

external_auth_flow() {  # $@ = accounts to (re)authenticate
  local accts=("$@") acct attempt rc trigger_pid
  say "OAuth external-authentication for: ${accts[*]}"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    warn "DRY_RUN: would stop emailproxy.service, run emailproxy --external-auth in"
    warn "DRY_RUN: this terminal (it shows the OAuth URL and takes your pasted URL),"
    warn "DRY_RUN: triggering an IMAP login per account until it is accepted."
    return 0
  fi

  EP_LOG=$(mktemp /tmp/nasrpi-emailproxy-auth.XXXXXX)
  ep_stop_service
  trap 'ep_restore_service' EXIT INT

  warn "emailproxy runs in the foreground now and will prompt you directly."
  warn "Sign in at the URL it shows, then paste the browser's final URL at its prompt. (Ctrl-C aborts)"

  # stdin stays attached to this terminal (emailproxy needs a tty for this mode);
  # output is tee'd here so we can point at the URL it logs.
  "$EP_BIN" --no-gui --external-auth --config-file "$EP_ACCOUNTS" > >(tee "$EP_LOG") 2>&1 &
  ep_pid=$!
  sleep 3                                  # let the proxy bind its local ports

  for acct in "${accts[@]}"; do
    attempt=1; rc=1
    while (( attempt <= EP_AUTH_TRIES )) && kill -0 "$ep_pid" 2>/dev/null; do
      say "Account $acct (attempt $attempt/$EP_AUTH_TRIES): logging in through the proxy"
      auth_trigger "$acct" &
      trigger_pid=$!
      show_auth_url "$acct" || true              # convenience echo; the prompt is emailproxy's
      if wait "$trigger_pid"; then rc=0; else rc=$?; fi
      if [ "$rc" -eq 0 ]; then
        ok "$acct: login accepted -- OAuth token in place"
        break
      elif [ "$rc" -eq 4 ]; then
        warn "$acct: login refused (attempt $attempt) -- did the browser flow finish?"
      else
        warn "$acct: could not complete a login through the proxy (exit $rc)"
      fi
      attempt=$((attempt + 1))
      sleep 3
    done
    [ "$rc" -eq 0 ] || warn "Giving up on $acct for now -- rerun 02 to retry its OAuth flow."
  done

  ep_restore_service
}

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
default_folder() {  # tim.felgentreff@oracle.com -> oracle ; fallback: whole address
  local a=$1 d=${1##*@}
  d=${d%%.*}
  if printf '%s' "$d" | grep -qE '^[A-Za-z][A-Za-z0-9_-]*$'; then
    printf '%s\n' "$d"
  else
    printf '%s\n' "$a" | tr -c 'A-Za-z0-9_-' '_'
  fi
}

if run_once "write mbsync-mailbox-names to $MAPS_FILE"; then
  : > "$MAPS_FILE.tmp"
  for a in "${ACCOUNTS[@]}"; do
    d=$(default_folder "$a")
    n=$d; i=2
    while grep -q "=$n\$" "$MAPS_FILE.tmp" 2>/dev/null; do n="${d}-$i"; i=$((i+1)); done
    read -r -p "  Mail folder name for '$a' [${n}]: " custom || custom=""
    echo "${a}=${custom:-$n}" >> "$MAPS_FILE.tmp"
  done
  mkdir -p "$(dirname "$MAPS_FILE")" && mv "$MAPS_FILE.tmp" "$MAPS_FILE"
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
  local a name dest imap_ssl
  imap_ssl=$([ "$IMAP_TLS" = "on" ] && echo STARTTLS || echo None)
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
Pass ${EP_PASSWORD:-*}
AuthMechs LOGIN
# The proxy talks plain text locally and does the upstream TLS itself;
# STARTTLS only when the proxy config sets local_starttls = True.
SSLType $imap_ssl

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
  if [ "${DRY_RUN:-0}" != "1" ] && run_once "mbsync -c $MBSYNCRC"; then
    echo "  First sync (tokens acquired via the external-auth flow above)."
    mbsync -c "$MBSYNCRC" -a || warn "initial sync failed (is emailproxy running?)"
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
  # localhost <-> proxy is plain text; the proxy TLS-wraps the real upstream.
  if [ "$SMTP_TLS" = "on" ]; then echo "tls starttls"; else echo "tls off"; fi
  echo
  echo "account emailproxy"
  echo "host $SMTP_HOST"
  echo "port $SMTP_PORT"
  echo "from $smtp_account"
  if [ -n "$EP_PASSWORD" ]; then
    echo "auth on"
    echo "user $smtp_account"
    echo "password $EP_PASSWORD"
  else
    echo "auth off"
  fi
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
         | sendmail -t 2>/dev/null; then
      ok "sendmail (msmtp) relays through emailproxy as $smtp_account"
    else
      warn "test send failed -- check $MSMTPRC and that emailproxy is running"
    fi
  fi
fi

say "02 done."
