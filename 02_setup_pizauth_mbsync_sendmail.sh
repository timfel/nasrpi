#!/usr/bin/env bash
# 02_setup_pizauth_mbsync_sendmail.sh
#
# What this sets up
#   - pizauth (ltratt/pizauth, an OAuth2 token daemon) built from source with
#     rustup/cargo AS A NORMAL USER and installed under /opt/pizauth.
#   - systemd service 'pizauth': starts at boot, config /etc/pizauth.conf, runs
#     as root -- mbsync's cron job, sendmail and smartd all run as root too, and
#     pizauth's socket directory is 0700 for whoever runs the server.
#   - /etc/pizauth.conf: one `account "name" { ... }` block per mail account,
#     created interactively (Gmail / Office 365 presets). 02 reads accounts back
#     with awk (the address is the block's login_hint) -- no python, no helper
#     daemon of our own. Account blocks are kept verbatim when the file is
#     regenerated, so hand edits inside a block survive a rerun.
#   - tokens survive reboots: pizauth's token_event_cmd dumps them on every
#     change, startup_cmd restores them when the server starts. pizauth's dump is
#     NOT encrypted, only obfuscated, so we always seal it with gpg using a key
#     derived from THIS LAN (the gateway's UPnP id, whose UUID embeds the
#     router's MAC): a stolen Pi boots somewhere else, cannot derive the key and
#     stays at "please authorise". Nothing unencrypted ever hits the disk.
#   - OAuth sign-in: 02 prints the authorisation URL, you open it on your laptop
#     through an `ssh -L` tunnel to the Pi's loopback callback port; 02 polls
#     until the token lands. Nothing to paste back, no second shell.
#     `--force-auth` (or FORCE_AUTH=1) drops a token with `pizauth revoke
#     <account>` first, so you can redo a sign-in on purpose.
#
#   - /etc/mbsyncrc: XOAUTH2 + TLS straight to the provider (no local proxy),
#     pulling *down only* into /media/nas/Mail/<MAILBOX>. Gmail defaults to
#     '[Google Mail]/All Mail' ONLY: that folder already contains inbox and sent
#     mail, so syncing more folders just stores duplicates. Per-account tweaks
#     (folder, Patterns, IMAP/SMTP hosts) live in /etc/nasrpi-mailmaps.
#   - weekly mbsync cron. Skipping is fine: no NAS mount, or no pizauth socket
#     -> the run logs one line, exits 0 and next week's run catches up.
#   - /etc/msmtprc + msmtp-mta: sendmail relays to the provider with XOAUTH2,
#     token from pizauth as well.
#
# Run it as your normal user (it uses sudo where root is needed; cargo builds
# into your HOME, not root's).
# Usage: ./02_setup_pizauth_mbsync_sendmail.sh [--force-auth[=<account>]]
#        DRY_RUN=1 ./02_setup_pizauth_mbsync_sendmail.sh    # look, don't touch
#   Env overrides used mostly by the tests: STATE_DIR, NASRPI_PIZAUTH_DEFAULTS.
#
# pizauth's state stays in /var/lib/pizauth -- never under /media/nas, which
# script 05 mirrors to a backup disk (live OAuth tokens never leave the Pi).
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# --- paths / constants --------------------------------------------------------
PIZAUTH_VERSION=pizauth-1.1.1                    # pizauth is NOT on crates.io
PIZAUTH_REPO=https://github.com/ltratt/pizauth
PREFIX=/opt/pizauth
PIZAUTH_BIN="$PREFIX/bin/pizauth"
PIZAUTH_WRAPPER=/usr/local/bin/pizauth           # pins pizauth's socket for everyone
EP_KEY=/usr/local/bin/nasrpi-pizauth-key
EP_DUMP=/usr/local/bin/nasrpi-pizauth-dump
EP_RESTORE=/usr/local/bin/nasrpi-pizauth-restore
EP_NOTIFY=/usr/local/bin/nasrpi-pizauth-notify

PIZAUTH_CONF="$NASRPI_ETC_DIR/pizauth.conf"      # client secrets -> mode 0600
PIZAUTH_CONF_VIEW=$(drify "$PIZAUTH_CONF")
DEFAULTS_FILE="$NASRPI_ETC_DIR/default/nasrpi-pizauth"
DEFAULTS_VIEW=$(drify "$DEFAULTS_FILE")
MAPS_FILE="$NASRPI_ETC_DIR/nasrpi-mailmaps"
MAPS_VIEW=$(drify "$MAPS_FILE")
MBSYNCRC="$NASRPI_ETC_DIR/mbsyncrc"
MSMTPRC="$NASRPI_ETC_DIR/msmtprc"
MSMTPRC_VIEW=$(drify "$NASRPI_ETC_DIR/msmtprc")
STATE_DIR=/var/lib/pizauth
GPG_HOME="$STATE_DIR/gnupg"
XDG_RT=/run/pizauth          # socket ends up at /run/pizauth/pizauth/pizauth.sock

AUTH_PORT_DEFAULT=19024
GATEWAY_DEFAULT=192.168.178.1                    # FRITZ!Box
UPNP_PORT_DEFAULT=49000

# FORCE_AUTH=all (or --force-auth) redoes every sign-in; FORCE_AUTH=<account>
# (or --force-auth=<account>) redoes one. Useful when a token went stale or you
# changed an account's scopes.
FORCE_AUTH=${FORCE_AUTH:-}
for arg in "$@"; do
  case "$arg" in
    --force-auth)   FORCE_AUTH=all ;;
    --force-auth=*) FORCE_AUTH=${arg#*=} ;;
    -h|--help)
      echo "usage: ./02_setup_pizauth_mbsync_sendmail.sh [--force-auth[=<account>]]"
      echo "  --force-auth           redo the OAuth sign-in of every account"
      echo "  --force-auth=NAME      ... or just one account"
      echo "  DRY_RUN=1              print what would happen, change nothing"
      exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done
force_auth_for() { [ "$FORCE_AUTH" = all ] || [ "$FORCE_AUTH" = "$1" ]; }
if [ -n "$FORCE_AUTH" ]; then
  warn "--force-auth: tokens get dropped locally (pizauth revoke) and re-issued,"
  warn "so every affected account needs a browser sign-in during this run."
fi

# Cache sudo rights up front: this script asks a lot of questions and the first
# root action would otherwise land a password prompt in the middle of a build.
if [ "${DRY_RUN:-0}" != "1" ] && [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1; then
  sudo -v || die "sudo is needed for the install steps (or run as root)."
fi

say "02 - pizauth + mbsync + sendmail"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# kv_get FILE KEY DEFAULT -- values are taken literally, quotes included (which
# is exactly what mbsync's Patterns wants to see).
kv_get() {
  local v=""
  if [ -f "$1" ]; then
    v=$(awk -F= -v k="$2" '$1==k { sub(/^[^=]*=/, ""); v=$0 } END { print v }' "$1" 2>/dev/null || true)
  fi
  [ -n "$v" ] || v=$3
  printf '%s\n' "$v"
}

# --- build pizauth ------------------------------------------------------------
if [ -x "$PIZAUTH_BIN" ]; then
  ok "pizauth installed at $PIZAUTH_BIN"
elif [ "${DRY_RUN:-0}" = "1" ]; then
  warn "DRY_RUN: would build pizauth $PIZAUTH_VERSION into $PREFIX"
elif confirm "Install pizauth $PIZAUTH_VERSION under $PREFIX (cargo build, slow on a Pi)?"; then
  # The build runs as whoever runs this script: rustup/cargo keep their state in
  # $HOME, and root's HOME would do as well but then a rebuild needs root too.
  [ "$(id -u)" = 0 ] && warn "building as root: rust will write to $HOME/.cargo"
  apt_install build-essential pkg-config git ca-certificates curl
  if ! command -v cargo >/dev/null 2>&1; then
    say "cargo is missing -- installing rustup for user '$(id -un)' (not system-wide)"
    confirm "Install rustup + Rust stable for $(id -un)?" || die "cargo is required to build pizauth."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain stable
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  cargo --version
  # Build as the calling user into a staging root: `cargo install` writes into
  # $CARGO_HOME, and doing that as root would root-own parts of ~/.cargo.
  stage="$PWD/.tmp/pizauth-root"
  rm -rf "$stage"
  cargo install --locked --git "$PIZAUTH_REPO" --tag "$PIZAUTH_VERSION" --root "$stage" pizauth
  [ -x "$stage/bin/pizauth" ] || die "cargo finished but $stage/bin/pizauth is missing"
  $NASRPI_SUDO mkdir -p "$PREFIX"
  $NASRPI_SUDO cp -a "$stage"/. "$PREFIX"/
  ok "installed $PIZAUTH_BIN ($("$PIZAUTH_BIN" --version))"
else
  die "pizauth is required for the rest of this script."
fi

# --- runtime packages ---------------------------------------------------------
apt_install isync msmtp msmtp-mta ca-certificates curl
# isync has no built-in XOAUTH2 -- it needs the Cyrus SASL plugin.
if apt-cache show libsasl2-modules-kdexoauth2 >/dev/null 2>&1; then
  apt_install libsasl2-modules-kdexoauth2
else
  warn "libsasl2-modules-kdexoauth2 is not in your apt archive."
  warn "mbsync's XOAUTH2 needs a Cyrus SASL XOAUTH2 plugin -- install one before syncing."
fi
command -v curl >/dev/null 2>&1 || apt_install curl
# gpg seals the token dump. (pizauth's docs suggest 'age -p', but neither age
# nor rage can read a passphrase without a terminal, so it cannot run at boot.)
command -v gpg >/dev/null 2>&1 || apt_install gnupg

# --- token storage (/etc/default/nasrpi-pizauth) ------------------------------
# There is exactly one storage mode: pizauth's dump, sealed with gpg using a key
# derived from the LAN. Storing tokens unencrypted is not offered.
GATEWAY_PREV=$(kv_get "$DEFAULTS_VIEW" GATEWAY "$GATEWAY_DEFAULT")
UPNP_PORT_PREV=$(kv_get "$DEFAULTS_VIEW" UPNP_PORT "$UPNP_PORT_DEFAULT")
AUTH_PORT_PREV=$(kv_get "$DEFAULTS_VIEW" AUTH_PORT "$AUTH_PORT_DEFAULT")
SSH_PREV=$(kv_get "$DEFAULTS_VIEW" SSH_TARGET "$(id -un)@$(hostname -f 2>/dev/null || hostname)")

say "token storage: tokens survive a reboot, sealed to this LAN"
echo "  pizauth dumps its token state whenever it changes and restores it when the"
echo "  server starts, so a reboot does not mean signing in again. pizauth's own"
echo "  docs are blunt that such a dump is NOT encrypted, only obfuscated -- so we"
echo "  seal it with gpg, key derived from THIS LAN: the gateway's UPnP id, whose"
echo "  UUID embeds the router's MAC and which can only be read without a password"
echo "  from inside your own LAN. A Pi booting anywhere else cannot derive the key"
echo "  and simply stays at \"please authorise\"."
DUMP_FILE="$STATE_DIR/tokens.dump.gpg"

if [ -f "$DEFAULTS_VIEW" ]; then
  echo "  On record (edit $DEFAULTS_FILE any time):"
  sed 's/^/    /' "$DEFAULTS_VIEW"
fi
LAN_GATEWAY=""; UPNP_PORT=""; AUTH_PORT=""; SSH_TARGET=""
if [ ! -f "$DEFAULTS_VIEW" ] || confirm "Set gateway and ports now?"; then
  ask LAN_GATEWAY "Gateway IP (your FRITZ!Box)" "$GATEWAY_PREV"
  ask UPNP_PORT   "Router UPnP port (where igddesc.xml lives)" "$UPNP_PORT_PREV"
  ask AUTH_PORT   "Local OAuth callback port (used by the ssh tunnel)" "$AUTH_PORT_PREV"
  ask SSH_TARGET  "ssh target you use for this Pi (for the sign-in tunnel)" "$SSH_PREV"
else
  LAN_GATEWAY=$GATEWAY_PREV; UPNP_PORT=$UPNP_PORT_PREV
  AUTH_PORT=$AUTH_PORT_PREV; SSH_TARGET=$SSH_PREV
fi
[ -n "$AUTH_PORT" ] || AUTH_PORT=$AUTH_PORT_DEFAULT
[ -n "$SSH_TARGET" ] || SSH_TARGET="$SSH_PREV"

# --- helper scripts -----------------------------------------------------------
say "installing pizauth helper scripts"

# pizauth finds its server socket in $XDG_RUNTIME_DIR; sudo keeps a user's
# XDG_RUNTIME_DIR, which would point at another server -- so pin it everywhere.
write_file 755 "$PIZAUTH_WRAPPER" "sudo" "force" <<EOF || die "$PIZAUTH_WRAPPER is needed so mbsync/sendmail reach pizauth"
#!/bin/sh
# Managed by nasrpi setup scripts (02): always talk to THE pizauth server.
[ -r "\${NASRPI_PIZAUTH_DEFAULTS:-$DEFAULTS_FILE}" ] && . "\${NASRPI_PIZAUTH_DEFAULTS:-$DEFAULTS_FILE}"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-$XDG_RT}"
exec "\${PIZAUTH_BIN:-$PIZAUTH_BIN}" "\$@"
EOF

write_file 755 "$EP_KEY" "sudo" "force" <<EOF
#!/bin/sh
# Managed by nasrpi setup scripts (02).
#
# nasrpi-pizauth-key udn      -> print the gateway's UPnP UDN
# nasrpi-pizauth-key key      -> print the passphrase that seals the token dump
# nasrpi-pizauth-key seal     # stdin plain  -> stdout sealed
# nasrpi-pizauth-key unseal   # stdin sealed -> stdout plain
#
# The passphrase is DERIVED and never stored: SHA-256 over the gateway's UPnP
# UDN (that UUID embeds the router's MAC). It can only be read from inside your
# own LAN, so a stolen Pi booting elsewhere cannot open the dump. Anyone who is
# physically in your LAN -- or who steals the router too -- can derive it too;
# that is the trade-off we accepted.
#
# Reading the UDN is the only thing that needs the LAN, so this helper is also
# the "are we at home" test: no UDN, no key, no restored tokens.
set -eu
[ -r "\${NASRPI_PIZAUTH_DEFAULTS:-$DEFAULTS_FILE}" ] && . "\${NASRPI_PIZAUTH_DEFAULTS:-$DEFAULTS_FILE}"
GW="\${GATEWAY:-$GATEWAY_DEFAULT}"
PORT="\${UPNP_PORT:-$UPNP_PORT_DEFAULT}"
TIMEOUT="\${LAN_TIMEOUT:-5}"

udn() {
  # A UDN written into the defaults file wins: handy for gateways without UPnP,
  # and it lets the sealing helpers be tested without a router around.
  if [ -n "\${UDN:-}" ]; then printf '%s' "\$UDN"; return 0; fi
  for base in "http://\$GW:\$PORT" "http://\$GW" "http://fritz.box:\$PORT"; do
    curl -fsS -m "\$TIMEOUT" "\$base/igddesc.xml" 2>/dev/null |
      awk 'match(\$0, /<UDN>[^<]+<\/UDN>/) { s = substr(\$0, RSTART + 5, RLENGTH - 11); print s; exit }'
  done | awk 'NF { print; exit }'
}

key() {   # the seal passphrase: derived on the spot, never stored anywhere
  u=\$(udn)
  [ -n "\$u" ] || { echo "nasrpi-pizauth-key: no UPnP UDN from http://\$GW:\$PORT -- not in your LAN?" >&2; exit 1; }
  printf '%s' "nasrpi-pizauth-v1|\$u" | sha256sum | cut -d' ' -f1
}

gpg_home() {   # gpg needs a PRIVATE homedir; create it on first use
  h=\${GPG_HOMEDIR:-$GPG_HOME}
  if [ ! -d "\$h" ]; then
    mkdir -p "\$h" && chmod 700 "\$h"   # fails (loudly) unless we may -- at boot this runs as root
  fi
  printf '%s' "\$h"
}

case "\${1:-key}" in
  udn)
    udn ;;
  key)
    key ;;
  seal)
    kf=\$(mktemp); chmod 600 "\$kf"
    trap 'rm -f "\$kf"' EXIT
    key > "\$kf"
    gpg --batch --no-tty --no-permission-warning --homedir "\$(gpg_home)" \\
        --pinentry-mode loopback --passphrase-file "\$kf" \\
        --symmetric --cipher-algo AES256 -o -
    ;;
  unseal)
    kf=\$(mktemp); chmod 600 "\$kf"
    trap 'rm -f "\$kf"' EXIT
    key > "\$kf"
    gpg --batch --quiet --no-tty --no-permission-warning --homedir "\$(gpg_home)" \\
        --pinentry-mode loopback --passphrase-file "\$kf" -d
    ;;
  *)
    echo "usage: nasrpi-pizauth-key [udn|key|seal|unseal]" >&2; exit 2 ;;
esac
EOF

# token_event_cmd: keep the on-disk dump current, always sealed.
write_file 755 "$EP_DUMP" "sudo" "force" <<EOF
#!/bin/sh
# Managed by nasrpi setup scripts (02): pizauth's token_event_cmd.
# Runs as root after every token change. pizauth's dump is NOT encrypted (only
# obfuscated), so it is always sealed with the LAN-derived key before it hits
# the disk -- nothing readable by a thief is ever written. Runs as root, and
# pizauth gives this ten seconds.
set -eu
[ -r "\${NASRPI_PIZAUTH_DEFAULTS:-$DEFAULTS_FILE}" ] && . "\${NASRPI_PIZAUTH_DEFAULTS:-$DEFAULTS_FILE}"
BIN=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)   # helpers live side by side
DUMP_FILE=\${DUMP_FILE:-$STATE_DIR/tokens.dump.gpg}
umask 077
dir=\$(dirname "\$DUMP_FILE")
mkdir -p "\$dir"; chmod 700 "\$dir"
tmp=\$(mktemp "\$dir/.dump.XXXXXX")
trap 'rm -f "\$tmp" "\$tmp.sealed"' EXIT
if ! "\$BIN/pizauth" dump > "\$tmp"; then
  logger -t nasrpi-pizauth "token dump failed (is the pizauth server up?)"
  exit 1
fi
if ! "\$BIN/nasrpi-pizauth-key" seal < "\$tmp" > "\$tmp.sealed"; then
  logger -t nasrpi-pizauth -p mail.err "no LAN key (gateway UPnP unreadable?) -- keeping the previous dump"
  exit 1
fi
mv -f "\$tmp.sealed" "\${DUMP_FILE:-$STATE_DIR/tokens.dump.gpg}"
chmod 600 "\${DUMP_FILE:-$STATE_DIR/tokens.dump.gpg}"
EOF

# startup_cmd: come back up with tokens, unattended.
write_file 755 "$EP_RESTORE" "sudo" "force" <<EOF
#!/bin/sh
# Managed by nasrpi setup scripts (02): pizauth's startup_cmd.
# Opens the sealed dump with the LAN-derived key -- which only works at home --
# and feeds it to pizauth. Anywhere else the key cannot be derived, the dump
# stays sealed and pizauth just waits for a fresh sign-in.
set -eu
[ -r "\${NASRPI_PIZAUTH_DEFAULTS:-$DEFAULTS_FILE}" ] && . "\${NASRPI_PIZAUTH_DEFAULTS:-$DEFAULTS_FILE}"
log() { logger -t nasrpi-pizauth "\$*"; }
BIN=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)   # helpers live side by side
DUMP_FILE=\${DUMP_FILE:-$STATE_DIR/tokens.dump.gpg}
if [ ! -s "\$DUMP_FILE" ]; then
  log "no token dump in \$DUMP_FILE yet -- nothing to restore"
  exit 0
fi
plain=\$(mktemp); chmod 600 "\$plain"
trap 'rm -f "\$plain"' EXIT
if ! "\$BIN/nasrpi-pizauth-key" unseal < "\$DUMP_FILE" > "\$plain"; then
  log "cannot open \$DUMP_FILE -- not your LAN (new router, UPnP off), or the dump needs resealing; rerun 02"
  exit 0
fi
# pizauth binds the socket shortly before it starts accepting, so retry a bit.
ok=0
i=1
while [ "\$i" -le 10 ]; do
  if "\$BIN/pizauth" restore < "\$plain"; then ok=1; break; fi
  i=\$((i+1)); sleep 2
done
if [ "\$ok" = 1 ]; then
  log "restored token state from \$DUMP_FILE"
else
  log "pizauth restore failed -- tokens may need re-authorisation"
fi
EOF

write_file 755 "$EP_NOTIFY" "sudo" "force" <<EOF
#!/bin/sh
# Managed by nasrpi setup scripts (02): pizauth's auth_notify_cmd / error_notify_cmd.
# pizauth gives these 10 seconds, so only ever talk to the log here.
case "\${1:-auth}" in
  auth) logger -t nasrpi-pizauth -p mail.warning \\
          "account '\$PIZAUTH_ACCOUNT' needs sign-in: \$PIZAUTH_URL" ;;
  *)    logger -t nasrpi-pizauth -p mail.err \\
          "account '\$PIZAUTH_ACCOUNT': \$PIZAUTH_MSG" ;;
esac
EOF

# --- state dir ----------------------------------------------------------------
# Created BEFORE the round trip below: the seal key's gpg homedir lives inside
# it, and gpg must be able to create/use its homedir for the probe to work.
if [ "${DRY_RUN:-0}" != "1" ]; then
  $NASRPI_SUDO mkdir -p "$STATE_DIR" "$GPG_HOME"
  $NASRPI_SUDO chmod 700 "$STATE_DIR" "$GPG_HOME"
  ok "state dir $STATE_DIR (0700, root) -- deliberately not under /media/nas"
fi

# --- prove the LAN key works --------------------------------------------------
# Without a readable gateway UDN there is no key, so the dump could never be
# opened again. Say so loudly instead of writing a dump nobody can unlock.
say "LAN key: probing your gateway"
if [ "${DRY_RUN:-0}" = "1" ]; then
  warn "DRY_RUN: would read the gateway UDN from http://$LAN_GATEWAY:$UPNP_PORT/igddesc.xml"
  warn "DRY_RUN: would round-trip a test secret through nasrpi-pizauth-key seal|unseal"
else
  LAN_OK=1
  udn=$($EP_KEY udn || true)
  if [ -n "$udn" ]; then
    ok "gateway UDN: $udn   (its tail is the router's MAC)"
  else
    LAN_OK=0
    warn "could not read a UPnP UDN from http://$LAN_GATEWAY:$UPNP_PORT/igddesc.xml"
    warn "Without it the token dump can never be opened, so nothing gets sealed and"
    warn "every reboot means signing in again."
  fi
  # Run the probe AS ROOT, the identity that seals/restores at runtime (the
  # gpg homedir under $STATE_DIR is root 0700, so an unprivileged probe could
  # never open it). The defaults file does not exist yet, so pass the probed
  # gateway through the environment explicitly.
  if [ "$LAN_OK" = 1 ] && printf 'nasrpi round trip\n' \
       | $NASRPI_SUDO env GATEWAY="$LAN_GATEWAY" UPNP_PORT="$UPNP_PORT" "$EP_KEY" seal 2>/dev/null \
       | $NASRPI_SUDO env GATEWAY="$LAN_GATEWAY" UPNP_PORT="$UPNP_PORT" "$EP_KEY" unseal 2>/dev/null \
       | grep -q 'nasrpi round trip'; then
    ok "seal/unseal round trip works"
  else
    LAN_OK=0
    warn "seal/unseal round trip FAILED -- the dump stays unusable"
  fi
  if [ "$LAN_OK" != 1 ]; then
    confirm "Continue anyway (sign in again after every reboot)?" \
      || die "fix the gateway settings (or UPnP) and rerun 02"
  fi
fi

# --- defaults file ------------------------------------------------------------
{
  echo "# Managed by nasrpi setup scripts (02_setup_pizauth_mbsync_sendmail.sh)."
  echo "# Read by the nasrpi-pizauth-* helpers, /usr/local/bin/pizauth and the"
  echo "# pizauth systemd unit. No secrets here; edit freely and rerun 02."
  echo "PIZAUTH_BIN=$PIZAUTH_BIN"
  echo "XDG_RUNTIME_DIR=$XDG_RT"
  echo "DUMP_FILE=$DUMP_FILE"
  echo "GPG_HOMEDIR=$GPG_HOME"
  echo "GATEWAY=$LAN_GATEWAY"
  echo "UPNP_PORT=$UPNP_PORT"
  echo "# Leave UDN empty: the seal key is then derived from the router over UPnP,"
  echo "# which is only possible from inside your LAN. Setting it stores the key"
  echo "# material on this disk, so tokens stay sealed against a stolen Pi but not"
  echo "# against someone who has the Pi in your house. Only set it if the router"
  echo "# has no UPnP (it is the uuid:... from its igddesc.xml)."
  echo "UDN=$(kv_get "$DEFAULTS_VIEW" UDN '')"
  echo "AUTH_PORT=$AUTH_PORT"
  echo "SSH_TARGET=$SSH_TARGET"
} | write_file 644 "$DEFAULTS_FILE" "sudo" "force" || true

# --- accounts in /etc/pizauth.conf -------------------------------------------
# pizauth_account_list CONF    -> "name<TAB>login_hint" per account block
pizauth_account_list() {
  awk -v OFS='\t' '
    function emit() { if (inblk) { print acct, email; inblk = 0; acct = ""; email = "" } }
    {
      o = gsub(/\{/, "{"); c = gsub(/\}/, "}")        # brace depth, URLs have no braces
      if (!inblk && $0 ~ /^[ \t]*account[ \t]+"/) {
        a = $0; sub(/^[ \t]*account[ \t]*"/, "", a); sub(/".*/, "", a)
        acct = a; email = ""; inblk = 1; d = o - c
        if (d <= 0) emit()
        next
      }
      if (inblk) {
        if (email == "" && $0 ~ /"login_hint"[ \t]*:/) {
          v = $0; sub(/.*"login_hint"[ \t]*:[ \t]*"/, "", v); sub(/".*/, "", v); email = v
        }
        d += o - c
        if (d <= 0) emit()
        next
      }
    }
    END { emit() }
  ' "$1"
}

# pizauth_account_blocks CONF -- the account blocks verbatim (hand edits survive)
pizauth_account_blocks() {
  awk '
    {
      o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
      if (!inblk && $0 ~ /^[ \t]*account[ \t]+"/) {
        inblk = 1; d = 0
        if (seen) print ""   # blank line between account blocks
        seen = 1
      }
      if (inblk) { print; d += o - c; if (d <= 0) inblk = 0 }
    }' "$1"
}

# copy the current (root-only) config into $TMP so awk can read it
conf_copy="$TMP/conf"; : > "$conf_copy"
if [ -f "$PIZAUTH_CONF_VIEW" ]; then
  if [ -r "$PIZAUTH_CONF_VIEW" ]; then
    cp "$PIZAUTH_CONF_VIEW" "$conf_copy"
  elif [ "${DRY_RUN:-0}" = "1" ]; then
    warn "DRY_RUN: cannot read $PIZAUTH_CONF_VIEW, treating it as empty"
  else
    $NASRPI_SUDO cat "$PIZAUTH_CONF_VIEW" > "$conf_copy"
    chmod 600 "$conf_copy"
    ok "read $PIZAUTH_CONF"
  fi
fi

say "mail accounts in $PIZAUTH_CONF"
blocks_file="$TMP/blocks"; pizauth_account_blocks "$conf_copy" > "$blocks_file"
pizauth_account_list "$conf_copy" > "$TMP/accounts"
if [ -s "$TMP/accounts" ]; then
  while IFS=$'\t' read -r n e; do
    [ -n "$n" ] && echo "    $n -> ${e:-<no login_hint>}"
  done < "$TMP/accounts"
else
  echo "  No accounts yet."
fi

# --- OAuth app presets --------------------------------------------------------
auth_token_uri() {
  case "$1" in
    gmail)   printf '%s\n' 'https://oauth2.googleapis.com/token' ;;
    outlook) printf '%s\n' 'https://login.microsoftonline.com/common/oauth2/v2.0/token' ;;
    *) printf '%s\n' '' ;;
  esac
}

infer_provider() {   # by e-mail domain, empty when unknown
  case "${1##*@}" in
    gmail.com|googlemail.com) printf 'gmail\n' ;;
    outlook.com|hotmail.com|live.com|msn.com|outlook.de) printf 'outlook\n' ;;
    *) printf '\n' ;;
  esac
}

acct_name_of() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_'; }

# account_block NAME EMAIL PROVIDER CLIENT_ID CLIENT_SECRET
account_block() {
  local name=$1 email=$2 provider=$3 cid=$4 secret=$5 auth_uri scopes
  case "$provider" in
    gmail)
      auth_uri='https://accounts.google.com/o/oauth2/auth'
      scopes='["https://mail.google.com/"]' ;;
    outlook)
      auth_uri='https://login.microsoftonline.com/common/oauth2/v2.0/authorize'
      scopes='["https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send", "offline_access"]' ;;
    *) printf 'unknown provider %s\n' "$provider" >&2; return 1 ;;
  esac
  printf '\naccount "%s" {\n' "$name"
  printf '    client_id = "%s";\n' "$cid"
  if [ -n "$secret" ]; then printf '    client_secret = "%s";\n' "$secret"; fi
  printf '    auth_uri = "%s";\n' "$auth_uri"
  printf '    token_uri = "%s";\n' "$(auth_token_uri "$provider")"
  printf '    scopes = %s;\n' "$scopes"
  printf '    auth_uri_fields = { "login_hint": "%s" };\n' "$email"
  printf '}\n'
}

prompt_new_account() {
  local email provider client_id client_secret name n
  ask email "E-mail address of the new account"
  provider=$(infer_provider "$email")
  if [ -n "$provider" ]; then
    ok "using the $provider preset (fix it in $PIZAUTH_CONF afterwards if that is wrong)"
  else
    warn "no preset for the domain ${email##*@}"
    ask provider "OAuth app preset for $email (gmail or outlook)" "gmail"
  fi
  echo
  echo "Here are some client ids from thunderbird:"
  echo "  Google client_id: 406964657835-aq8lmia8j95dhl1a2bvharmfk3t1hgqj.apps.googleusercontent.com"
  echo "  Google client_secret: kSmqreRr0qwBWJgbf5Y-PjSU"
  echo "  Outlook client_id: 9e5f94bc-e8a4-4e73-b8be-63364c29d753"
  echo
  ask client_id "client_id of the $provider OAuth app for $email"
  ask client_secret "client_secret for $email (empty = none; many setups need none)"
  echo
  name=$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')
  n=1
  while grep -q "^account \"$name\" " "$conf_copy" "$new_blocks" 2>/dev/null; do
    n=$((n + 1)); name=$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')_$n
  done
  account_block "$name" "$email" "$provider" "$client_id" "$client_secret" >> "$new_blocks"
  ok "queued account '$name' ($email)"
}

new_blocks="$TMP/new-blocks"; : > "$new_blocks"
while :; do
  if confirm "Add a mail account to $PIZAUTH_CONF?"; then
    prompt_new_account
  else
    break
  fi
done

# --- write /etc/pizauth.conf --------------------------------------------------
conf_new="$TMP/conf.new"
{
  # echo "# Managed by nasrpi setup scripts (02). Accounts: one 'account' block each."
  # echo "# The text inside an existing account block is kept as-is when 02 reruns;"
  # echo "# global settings below come from $DEFAULTS_FILE."
  # echo
  # echo "# OAuth callback: only on loopback. Reach it from your laptop with"
  # echo "#   ssh -N -L 127.0.0.1:$AUTH_PORT:127.0.0.1:$AUTH_PORT $SSH_TARGET"
  # MUST be a literal IPv4 address, not "localhost": pizauth's TcpListener::bind
  # binds only the FIRST address getaddrinfo returns, and on a Pi "localhost"
  # usually resolves to ::1 first -- which makes the laptop's
  # `ssh -L 127.0.0.1:PORT:127.0.0.1:PORT` tunnel hit "Connection refused".
  # (The OAuth redirect_uri stays http://localhost:PORT/ regardless, so the
  # redirect URI registered with the provider is unaffected. This matches
  # pizauth's own README and its built-in default of 127.0.0.1:0.)
  printf 'http_listen = "127.0.0.1:%s";\n' "$AUTH_PORT"
  echo 'startup_cmd = "/bin/sh /usr/local/bin/nasrpi-pizauth-restore";'
  echo 'token_event_cmd = "/bin/sh /usr/local/bin/nasrpi-pizauth-dump";'
  echo 'auth_notify_cmd = "/bin/sh /usr/local/bin/nasrpi-pizauth-notify auth";'
  echo 'error_notify_cmd = "/bin/sh /usr/local/bin/nasrpi-pizauth-notify error";'
  echo
  cat "$blocks_file"
  cat "$new_blocks"
} > "$conf_new"

# Did anything actually change vs the installed config? (Restart decision below.)
conf_changed=1
if [ "${DRY_RUN:-0}" != "1" ] && [ -f "$PIZAUTH_CONF" ] \
   && $NASRPI_SUDO cmp -s "$PIZAUTH_CONF" "$conf_new" 2>/dev/null; then
  conf_changed=0
fi
# write_file only touches the file when something actually changed
write_file 600 "$PIZAUTH_CONF" "sudo" "force" < "$conf_new"
chmod 600 "$conf_new" 2>/dev/null || true
# let a running server pick up new/changed accounts
if [ "${DRY_RUN:-0}" != "1" ] && [ -s "$new_blocks" ]; then
  $NASRPI_SUDO "$PIZAUTH_WRAPPER" reload >/dev/null 2>&1 || true
fi

pizauth_account_list "$conf_new" > "$TMP/accounts"
if [ ! -s "$TMP/accounts" ]; then
  warn "No accounts configured in $PIZAUTH_CONF -- nothing to sync or send through."
  warn "Rerun 02 and add one."
  exit 0
fi
say "accounts:"
while IFS=$'\t' read -r n e; do [ -n "$n" ] && echo "    $n -> $e"; done < "$TMP/accounts"

# Everything below that asks a question iterates these arrays instead of the
# accounts file: a redirected stdin would swallow the answers typed in.
NAMES=(); EMAILS=()
while IFS=$'\t' read -r n e; do
  [ -n "$n" ] && { NAMES+=("$n"); EMAILS+=("$e"); }
done < "$TMP/accounts"


# --- systemd: one server, started at boot ------------------------------------
say "systemd service 'pizauth'"
{
  echo "# Managed by nasrpi setup scripts (02)."
  echo '[Unit]'
  echo 'Description=pizauth OAuth2 token manager (nasrpi)'
  echo 'Documentation=https://github.com/ltratt/pizauth'
  echo 'After=network-online.target'
  echo 'Wants=network-online.target'
  echo
  echo '[Service]'
  echo 'Type=simple'
  echo '# -d keeps pizauth in the foreground so its log goes to journald.'
  printf 'ExecStart=%s server -c %s -d\n' "$PIZAUTH_BIN" "$PIZAUTH_CONF"
  echo 'ExecReload=/usr/local/bin/pizauth reload'
  echo "# 'pizauth shutdown' asks the server to quit and waits for state to be written."
  echo 'ExecStop=/usr/local/bin/pizauth shutdown'
  echo '# pizauth runs startup_cmd/token_event_cmd through $SHELL, which systemd does'
  echo '# not set. XDG_RUNTIME_DIR pins the socket path for this unit AND for root cron'
  echo '# jobs, which otherwise keep the runtime dir of the invoking user.'
  echo 'Environment=SHELL=/bin/sh'
  printf 'Environment=XDG_RUNTIME_DIR=%s\n' "$XDG_RT"
  echo '# /run/pizauth holds the control socket: created at start, removed on stop.'
  echo 'RuntimeDirectory=pizauth'
  echo 'Restart=on-failure'
  echo 'RestartSec=10'
  echo
  echo '[Install]'
  echo 'WantedBy=multi-user.target'
} | write_file 644 "$NASRPI_ETC_DIR/systemd/system/pizauth.service" "sudo" "force" || true

if [ "${DRY_RUN:-0}" = "1" ]; then
  warn "DRY_RUN: would systemctl daemon-reload + enable --now pizauth"
else
  $NASRPI_SUDO systemctl daemon-reload
  if $NASRPI_SUDO systemctl is-active --quiet pizauth; then
    if [ "$conf_changed" = 1 ]; then
      # 'pizauth reload' updates accounts only; the http callback listener is
      # bound once when the server starts, so a config change (http_listen,
      # port ...) needs a full restart to take effect.
      warn "config changed -- restarting pizauth so the OAuth callback listener rebinds"
      $NASRPI_SUDO systemctl restart pizauth
    else
      ok "pizauth already running"
    fi
  else
    $NASRPI_SUDO systemctl enable --now pizauth
  fi
  for _ in $(seq 1 20); do
    [ -S "$XDG_RT/pizauth/pizauth.sock" ] && break
    sleep 0.5
  done
  if $NASRPI_SUDO "$PIZAUTH_WRAPPER" status >/dev/null 2>&1; then
    ok "pizauth server answering on $XDG_RT/pizauth/pizauth.sock"
  else
    $NASRPI_SUDO systemctl status pizauth --no-pager | tail -6 || true
    die "pizauth is not answering -- see: journalctl -u pizauth"
  fi
fi

# --- sign in: open the URL on your laptop ------------------------------------
sign_in_account() {   # NAME -> 0 once pizauth holds a token
  local name=$1 out url i
  if [ "${DRY_RUN:-0}" = "1" ]; then
    warn "DRY_RUN: would check the OAuth token of $name (and walk you through sign-in if missing)"
    return 0
  fi
  if force_auth_for "$name"; then
    # 'pizauth revoke' drops the token on this machine (it does not talk to the
    # provider), which makes the next 'show' hand out a fresh sign-in URL.
    if [ -S "$XDG_RT/pizauth/pizauth.sock" ] \
       && $NASRPI_SUDO "$PIZAUTH_WRAPPER" revoke "$name" >/dev/null 2>&1; then
      warn "$name: token dropped locally, signing in again"
    else
      warn "$name: --force-auth, but pizauth is not answering; cannot drop its token"
      return 1
    fi
  elif $NASRPI_SUDO "$PIZAUTH_WRAPPER" show "$name" >/dev/null 2>&1; then
    ok "$name: OAuth token present"
    return 0
  else
    warn "$name: no token yet -- one interactive sign-in is needed (only ever the first time)"
  fi
  # 'pizauth show' starts the request AND prints its URL; we then just wait.
  out=$($NASRPI_SUDO "$PIZAUTH_WRAPPER" show "$name" 2>&1 >/dev/null || true)
  url=$(printf '%s' "$out" | sed -n 's/.*with URL \(https[^ "]*\).*/\1/p' | head -n1)
  if [ -z "$url" ]; then
    warn "pizauth gave no authorisation URL for $name (account not in $PIZAUTH_CONF?)"
    return 1
  fi
  cat <<EOM

  Sign-in for $name
  -----------------
  1) On your laptop, open an ssh tunnel to this Pi's OAuth callback port:

       ssh -N -L 127.0.0.1:$AUTH_PORT:127.0.0.1:$AUTH_PORT $SSH_TARGET

  2) In your laptop's browser, open this URL:

       $url

  3) Finish the sign-in there. The page should end at "pizauth processing
     authentication" -- then close the ssh tunnel. Nothing to paste back here.

  Waiting for the token (up to ${POLL_TIMEOUT:-300}s), Ctrl-C gives up:
EOM
  for i in $(seq 1 $(( ${POLL_TIMEOUT:-300} / 5 ))); do
    if $NASRPI_SUDO "$PIZAUTH_WRAPPER" show "$name" >/dev/null 2>&1; then
      echo
      ok "$name: token is in pizauth"
      return 0
    fi
    sleep 5
    printf '.'
  done
  echo
  warn "$name: still no token after ${POLL_TIMEOUT:-300}s"
  return 1
}

say "OAuth tokens"
auth_missing=0
for i in "${!NAMES[@]}"; do
  sign_in_account "${NAMES[i]}" || auth_missing=$((auth_missing + 1))
done
if [ "$auth_missing" -gt 0 ]; then
  warn "$auth_missing account(s) have no token -- mail sync will fail until you sign in."
  warn "Any of them again later: sudo $PIZAUTH_WRAPPER show <account>"
fi

# --- per-account mail settings (/etc/nasrpi-mailmaps) ------------------------
# Plain key=value file, hand-editable, read back by 02. Values are literal, so
# Patterns keeps the quotes mbsync wants.
say "mail settings per account"
declare -A SET
if [ -f "$MAPS_VIEW" ]; then
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    SET["$k"]=$v
  done < "$MAPS_VIEW"
  ok "read $MAPS_FILE"
fi

mget() { local v="${SET["$1.$2"]:-}"; [ -n "$v" ] || v=$3; printf '%s\n' "$v"; }

preset_imap_host() { case "$1" in gmail) printf 'imap.gmail.com\n' ;; outlook) printf 'outlook.office365.com\n' ;; *) printf '\n' ;; esac; }
preset_smtp_host() { case "$1" in gmail) printf 'smtp.gmail.com\n' ;; outlook) printf 'smtp.office365.com\n' ;; *) printf '\n' ;; esac; }
preset_patterns()  { case "$1" in gmail) printf '"[Google Mail]/All Mail"\n' ;; *) printf '*\n' ;; esac; }

ask_account_mail() {   # NAME EMAIL -- fill SET for a new (or changed) account
  local name=$1 email=$2 provider folder patterns host port
  provider=$(infer_provider "$email")
  [ -n "$provider" ] || provider=$(mget "$name" provider gmail)
  echo "  Mail settings for $email (pizauth account '$name')."
  if [ "$(preset_patterns "$provider")" != '*' ]; then
    echo "  Note: for Gmail, '[Google Mail]/All Mail' already holds inbox and sent mail,"
    echo "  so pulling only that folder is enough; syncing more stores duplicates."
  fi
  ask folder "Mailbox folder for $email (below /media/nas/Mail)" "$(mget "$name" folder "$name")"
  ask patterns "mbsync Patterns for $email (* = every folder)" "$(mget "$name" patterns "$(preset_patterns "$provider")")"
  SET["$name.provider"]=$provider
  SET["$name.folder"]=$folder
  SET["$name.patterns"]=$patterns
  if [ "$provider" = custom ]; then
    ask host "IMAP host for $email" "$(mget "$name" imap_host '')"
    ask port "IMAP port for $email (993 = TLS)" "$(mget "$name" imap_port 993)"
    SET["$name.imap_host"]=$host; SET["$name.imap_port"]=$port
    ask host "SMTP host for $email" "$(mget "$name" smtp_host '')"
    ask port "SMTP port for $email (587 = STARTTLS)" "$(mget "$name" smtp_port 587)"
    SET["$name.smtp_host"]=$host; SET["$name.smtp_port"]=$port
  else
    SET["$name.imap_host"]=$(preset_imap_host "$provider")
    SET["$name.imap_port"]=993
    SET["$name.smtp_host"]=$(preset_smtp_host "$provider")
    SET["$name.smtp_port"]=587
  fi
  echo "    -> mail lands in /media/nas/Mail/$folder/$(printf '%s' "$patterns" | tr -d '"')"
}

for i in "${!NAMES[@]}"; do
  name=${NAMES[i]}; email=${EMAILS[i]}
  if [ -n "${SET["$name.folder"]:-}" ]; then
    echo "    $email -> /media/nas/Mail/$(mget "$name" folder '')  provider $(mget "$name" provider '?')  Patterns $(mget "$name" patterns '?')"
    confirm "Change $email's mail settings?" && ask_account_mail "$name" "$email"
  else
    ask_account_mail "$name" "$email"
  fi
done

# fill provider fallbacks for anything the maps file does not know
while IFS=$'\t' read -r name email; do
  [ -n "$name" ] || continue
  provider=${SET["$name.provider"]:-$(infer_provider "$email")}
  [ -n "${SET["$name.provider"]:-}" ] || SET["$name.provider"]=${provider:-gmail}
  [ -n "${SET["$name.folder"]:-}" ] || SET["$name.folder"]=$name
  [ -n "${SET["$name.patterns"]:-}" ] || SET["$name.patterns"]=$(preset_patterns "${SET["$name.provider"]}")
  [ -n "${SET["$name.imap_host"]:-}" ] || SET["$name.imap_host"]=$(preset_imap_host "${SET["$name.provider"]}")
  [ -n "${SET["$name.imap_port"]:-}" ] || SET["$name.imap_port"]=993
  [ -n "${SET["$name.smtp_host"]:-}" ] || SET["$name.smtp_host"]=$(preset_smtp_host "${SET["$name.provider"]}")
  [ -n "${SET["$name.smtp_port"]:-}" ] || SET["$name.smtp_port"]=587
done < "$TMP/accounts"

{
  echo "# Managed by nasrpi setup scripts (02). Edit freely, then rerun 02."
  echo "# Per-account mail routing; values are literal (Patterns keeps its quotes)."
  echo "#   <account>.folder     mail dir below /media/nas/Mail/"
  echo "#   <account>.patterns   mbsync Patterns (Gmail default: All Mail only)"
  echo "#   <account>.provider   gmail | outlook | custom"
  echo "#   <account>.imap_host/.imap_port/.smtp_host/.smtp_port"
  for k in $(printf '%s\n' "${!SET[@]}" | sort); do
    printf '%s=%s\n' "$k" "${SET[$k]}"
  done
} | write_file 644 "$MAPS_FILE" "sudo" "force" || true

# --- /etc/mbsyncrc ------------------------------------------------------------
build_mbsyncrc() {
  echo "# Managed by nasrpi setup scripts (02); accounts come from $PIZAUTH_CONF."
  echo "# TLS straight to the provider; the XOAUTH2 token comes from pizauth."
  echo "# Rerun 02 after editing $MAPS_FILE."
  echo
  while IFS=$'\t' read -r name email; do
    [ -n "$name" ] || continue
    folder=$(mget "$name" folder "$name")
    imap_port=$(mget "$name" imap_port 993)
    ssl_type=STARTTLS; [ "$imap_port" = 993 ] && ssl_type=IMAPS
    echo "IMAPAccount $name"
    echo "Host $(mget "$name" imap_host imap.gmail.com)"
    echo "Port $imap_port"
    echo "User $email"
    echo "# pizauth prints an access token; the Cyrus XOAUTH2 plugin sends it to the"
    echo "# provider. libsasl2-modules-kdexoauth2 provides the mechanism."
    echo "AuthMechs XOAUTH2"
    echo "PassCmd \"$PIZAUTH_WRAPPER show $name\""
    echo "SSLType $ssl_type"
    echo "CertificateFile /etc/ssl/certs/ca-certificates.crt"
    echo
    echo "IMAPStore ${name}-remote"
    echo "Account $name"
    echo
    echo "MaildirStore ${name}-local"
    echo "SubFolders Verbatim"
    echo "Path /media/nas/Mail/$folder/"
    echo "Inbox /media/nas/Mail/$folder"
    echo
    echo "Channel $name"
    echo "Master :${name}-remote:"
    echo "Slave :${name}-local:"
    patterns=$(mget "$name" patterns)
    case "$patterns" in
      *'All Mail'*) echo "# Gmail's All Mail already holds inbox and sent mail." ;;
    esac
    echo "Patterns $(mget "$name" patterns)"
    echo "SyncState *"
    echo "Sync Pull"
    echo
  done < "$TMP/accounts"
}

build_mbsyncrc | write_file 644 "$MBSYNCRC" "sudo" || true

# --- mail directories --------------------------------------------------------
if mountpoint -q /media/nas 2>/dev/null || [ -d /media/nas ]; then
  while IFS=$'\t' read -r name email; do
    [ -n "$name" ] || continue
    folder=$(mget "$name" folder "$name")
    # A maildir needs cur/tmp/new; mbsync builds nested folders itself.
    # (No brace expansion here: it would have to stay unquoted to work.)
    root="/media/nas/Mail/$folder"
    $NASRPI_SUDO mkdir -p "$root/cur" "$root/tmp" "$root/new"
    ok "/media/nas/Mail/$folder ready"
  done < "$TMP/accounts"
else
  warn "/media/nas is not mounted -- mail dirs not created, sync will skip until it is mounted"
fi

# --- sync now? --------------------------------------------------------------
if [ "${DRY_RUN:-0}" = "1" ]; then
  warn "DRY_RUN: would run mbsync -c $MBSYNCRC -a"
elif mountpoint -q /media/nas 2>/dev/null || [ -d /media/nas ]; then
  if confirm "Sync all accounts now (first Gmail run downloads All Mail, can take a while)?"; then
    if $NASRPI_SUDO env XDG_RUNTIME_DIR="$XDG_RT" mbsync -c "$MBSYNCRC" -a; then
      ok "sync finished"
    else
      warn "mbsync failed -- no token (see sign-in above) or XOAUTH2 plugin missing"
    fi
  fi
else
  warn "/media/nas not mounted -- skipping the initial sync"
fi

# --- weekly cron ------------------------------------------------------------
write_file 755 /usr/local/bin/nasrpi-mail-sync.sh "sudo" "force" <<EOF || warn "mail-sync helper not written"
#!/bin/sh
# nasrpi: pull the maildirs down. Skipping is fine -- a sync that cannot run
# today logs one line, exits 0 and next week's run picks the mail up:
#   - /media/nas not mounted   -> nothing to write into
#   - pizauth not answering    -> no token, mbsync would just fail
[ -r "\${NASRPI_PIZAUTH_DEFAULTS:-$DEFAULTS_FILE}" ] && . "\${NASRPI_PIZAUTH_DEFAULTS:-$DEFAULTS_FILE}"
mountpoint -q /media/nas || { echo "/media/nas is not mounted -- skipping the mail sync"; exit 0; }
"$PIZAUTH_WRAPPER" status >/dev/null 2>&1 \
  || { echo "pizauth is not answering (systemctl status pizauth) -- skipping the mail sync"; exit 0; }
exec mbsync -c $MBSYNCRC -a
EOF

# --- weekly sync cron --------------------------------------------------------
say "weekly mail sync"
ask_dow_hour MAIL
install_cron nasrpi-mail-sync "$MAIL_DOW $MAIL_HOUR $MAIL_MIN" /usr/local/bin/nasrpi-mail-sync.sh

# --- /etc/msmtprc (this is what /usr/sbin/sendmail uses) --------------------
say "outgoing mail: msmtp + sendmail"
build_msmtprc() {
  echo "# Managed by nasrpi setup scripts (02); accounts come from $PIZAUTH_CONF."
  echo "# /usr/sbin/sendmail (msmtp-mta) relays through this file, straight to the"
  echo "# provider over TLS, token from pizauth. Rerun 02 after editing the maps file."
  echo "defaults"
  echo "auth xoauth2"
  echo "tls on"
  echo "tls_trust_file /etc/ssl/certs/ca-certificates.crt"
  echo
  while IFS=$'\t' read -r name email; do
    [ -n "$name" ] || continue
    port=$(mget "$name" smtp_port 587)
    echo "account $name"
    echo "host $(mget "$name" smtp_host smtp.gmail.com)"
    echo "port $port"
    echo "from $email"
    echo "user $email"
    if [ "$port" = 465 ]; then echo "tls_starttls off"; else echo "tls_starttls on"; fi
    echo "# pizauth prints the access token for XOAUTH2"
    echo "passwordeval $PIZAUTH_WRAPPER show $name"
    echo
  done < "$TMP/accounts"
  echo "account default : $SMTP_DEFAULT"
}

SMTP_DEFAULT=""
acct_count=$(grep -c . "$TMP/accounts" || true)
if [ "$acct_count" = 1 ]; then
  IFS=$'\t' read -r SMTP_DEFAULT SMTP_EMAIL < "$TMP/accounts"
  ok "single account, sendmail uses: $SMTP_DEFAULT ($SMTP_EMAIL)"
else
  echo "  Which account should send system mail (scripts, smartd, cron)?"
  select pick in $(awk -F'\t' '{print $1}' "$TMP/accounts"); do
    if awk -F'\t' -v n="$pick" 'BEGIN{FS="\t"} $1==n{found=1} END{exit !found}' "$TMP/accounts"; then
      SMTP_DEFAULT=$pick
      break
    fi
    echo "  Pick one of the listed accounts."
  done
  if [ -z "$SMTP_DEFAULT" ]; then
    SMTP_DEFAULT=$(awk -F'\t' 'NF{print $1; exit}' "$TMP/accounts")
    warn "Using the first account for sendmail: $SMTP_DEFAULT"
  fi
fi
build_msmtprc | write_file 600 "$MSMTPRC" "sudo" || true

# --- proof that the whole chain works ---------------------------------------
if [ "${DRY_RUN:-0}" = "1" ]; then
  warn "DRY_RUN: would send a test mail through sendmail -> $MSMTPRC"
else
  test_to=""
  ask test_to "Send a test mail from $SMTP_DEFAULT to what email address? (empty = skip)" ""
  if [ -n "$test_to" ]; then
    if printf 'Subject: nasrpi test mail\n\nSent by 02_setup_pizauth_mbsync_sendmail.sh via pizauth + msmtp.\n' \
        | $NASRPI_SUDO sendmail -f "$SMTP_DEFAULT" "$test_to"; then
      ok "test mail handed to sendmail for $test_to"
    else
      warn "sendmail failed -- check: sudo $PIZAUTH_WRAPPER show $SMTP_DEFAULT, then journalctl -u pizauth"
    fi
  fi
fi

# --- wrap up ----------------------------------------------------------------
echo
say "done. state of things:"
cat <<EOM
  pizauth server  : systemctl status pizauth   (log: journalctl -u pizauth -f)
  pizauth config  : sudo cat $PIZAUTH_CONF
  token of account: sudo $PIZAUTH_WRAPPER show <account>
  token dump      : sealed -> $DUMP_FILE (key derived from the LAN)
  mail in         : mbsync -c $MBSYNCRC -a   (weekly, /etc/cron.d/nasrpi-mail-sync)
  mail out        : /usr/sbin/sendmail -> $MSMTPRC (default $SMTP_DEFAULT)
  per-account tweak: $MAPS_FILE, then rerun 02

  Notes
  - The dump is sealed with a key derived from your gateway's UPnP id. Replace
    the router (or switch its UPnP off) and it can no longer be opened: rerun
    02 to reseal it, or sign in again.
  - pizauth is built from $PIZAUTH_REPO @ $PIZAUTH_VERSION, so an apt upgrade
    will never swap it under you. Upgrade = rerun 02 with a new tag.
  - Nothing OAuth-related lives under /media/nas, so script 05 never copies it.
EOM
