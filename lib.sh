# lib.sh -- shared helpers for the nasrpi setup scripts.
# Sourced by 01..06. Keep it simple; edit freely.
#
# Test hooks (never needed on the real Pi):
#   DRY_RUN=1            ... print root-owned changes instead of applying them
#   NASRPI_FSTAB=path    ... override /etc/fstab location
#   NASRPI_CRON_DIR=path ... override /etc/cron.d location
#   NASRPI_ETC_DIR=path  ... override /etc location for generated configs

NASRPI_MOUNTS=(/media/media /media/media_backup /media/nas /media/nas_backup)
NASRPI_CRON_DIR="${NASRPI_CRON_DIR:-/etc/cron.d}"
NASRPI_ETC_DIR="${NASRPI_ETC_DIR:-/etc}"
NASRPI_FSTAB="${NASRPI_FSTAB:-/etc/fstab}"
NASRPI_DOW="${NASRPI_DOW:-0}"       # cron day of week: 0=Sunday .. 6=Saturday
NASRPI_HOUR="${NASRPI_HOUR:-3}"
NASRPI_MIN="${NASRPI_MIN:-15}"

if [ "${DRY_RUN:-0}" = "1" ] || [ -n "${NASRPI_DRY_ROOT:-}" ]; then
  NASRPI_SUDO=""
else
  NASRPI_SUDO="sudo"
fi

# --- interactive input ---------------------------------------------------------
# Questions must be answered from the terminal, not from stdin: callers hand
# content to functions on stdin (write_file reads the new file there, loops eat
# pipes), and a read from stdin in that situation swallows data instead of
# asking -- the prompt never appears and the answer silently becomes "no".
# So the questions read from fd 9, attached once here (before any caller
# redirects stdin):
#   NASRPI_INPUT=path      ... what to ask on (test harness: /dev/stdin)
#   default /dev/tty       ... the real terminal, even via ssh / `curl | sh`
#   else stdin             ... no terminal available at all
NASRPI_INPUT_FD=""
# NB: never write `exec 9< x 2>/dev/null' -- a redirection given to exec sticks
# to the shell, so that would silence stderr (prompts, warn, die) forever.
# Hence the readability tests up front and the redirections inside a group.
if { exec 9< "${NASRPI_INPUT:-/dev/tty}"; } 2>/dev/null; then
  NASRPI_INPUT_FD=9
elif { exec 9<&0; } 2>/dev/null; then
  NASRPI_INPUT_FD=9
fi

# nasrpi_read VAR "prompt" -> read one line from the interactive input into VAR;
# returns 1 on EOF (so callers can fall back to a default).  The prompt is
# printed here rather than via `read -p', which bash only shows when the fd it
# reads from looks like a terminal.
nasrpi_read() {
  local __var=$1 __prompt=$2 __ans="" __rc=0
  printf '%s' "$__prompt" >&2
  if [ -n "$NASRPI_INPUT_FD" ]; then
    read -u "$NASRPI_INPUT_FD" -r __ans || __rc=1
  else
    read -r __ans || __rc=1
  fi
  printf -v "$__var" '%s' "$__ans"
  return "$__rc"
}

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  [ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  [!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  [xx]\033[0m %s\n' "$*" >&2; exit 1; }

# ask VAR "prompt" "default" -> sets VAR (loops until non-empty unless default)
ask() {
  local __var=$1 __prompt=$2 __default=${3:-} __answer
  while :; do
    if ! nasrpi_read __answer "  ${__prompt}${__default:+ [${__default}]}: "; then
      # EOF: fall back to the default, or give up if there is none
      [ -n "$__default" ] || { echo; die "no input for '${__prompt}' and no default"; }
      __answer="$__default"
    fi
    [ -z "$__answer" ] && __answer="$__default"
    [ -n "$__answer" ] && break
    echo "  Please enter a value."
  done
  eval "$__var=\$__answer"
}

confirm() {
  local reply
  nasrpi_read reply "  $* [y/N] " || reply="n"
  [[ "$reply" =~ ^[Yy] ]]
}

# ask_dow_hour "variable-prefix" -> sets <prefix>_DOW, <prefix>_HOUR, <prefix>_MIN
ask_dow_hour() {
  local p=$1 dow hour min
  echo "  Cron day of week? 0=Sun 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri 6=Sat"
  while :; do
    nasrpi_read dow "  Day [${NASRPI_DOW}]: " || dow=""
    dow=${dow:-$NASRPI_DOW}
    [[ "$dow" =~ ^[0-6]$ ]] && break
    echo "  Pick 0-6."
  done
  while :; do
    nasrpi_read hour "  Hour 0-23 [${NASRPI_HOUR}]: " || hour=""
    hour=${hour:-$NASRPI_HOUR}
    [[ "$hour" =~ ^[0-9]{1,2}$ ]] && [ "$hour" -le 23 ] && break
    echo "  Pick 0-23."
  done
  while :; do
    nasrpi_read min "  Minute 0-59 [${NASRPI_MIN}]: " || min=""
    min=${min:-$NASRPI_MIN}
    [[ "$min" =~ ^[0-9]{1,2}$ ]] && [ "$min" -le 59 ] && break
    echo "  Pick 0-59."
  done
  eval "$p""_DOW=$dow; $p""_HOUR=$hour; $p""_MIN=$min"
}

# install_cron NAME "dow hour min" "command"   -> /etc/cron.d/<NAME> (idempotent)
install_cron() {
  local name=$1 spec=$2 cmd=$3 tmp
  local dest="$(drify "$NASRPI_CRON_DIR/$1")"
  local dow rest hour min
  dow=${spec%% *}
  rest=${spec#* }
  hour=${rest%% *}
  min=${rest##* }
  local content="# Managed by nasrpi setup scripts (cron entry: $name)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$min $hour * * $dow root $cmd
"
  if [ -f "$dest" ] && [ "$(grep -v '^# Managed by' "$dest")" = "$(echo "$content" | grep -v '^# Managed by')" ]; then
    ok "cron /etc/cron.d/$name already correct"
    return 0
  fi
  say "Installing cron job /etc/cron.d/$name:"
  echo "$content" | sed 's/^/    /'
  if confirm "Install this cron job?"; then
    tmp=$(mktemp)
    printf '%s' "$content" > "$tmp"
    if [ "${DRY_RUN:-0}" = "1" ] && [ -z "${NASRPI_DRY_ROOT:-}" ]; then
      warn "DRY_RUN: would install $dest"
    else
      # unquoted: NASRPI_SUDO is empty when already root ("$var" cmd would run "")
      $NASRPI_SUDO mkdir -p "$(dirname "$dest")"
      $NASRPI_SUDO cp "$tmp" "$dest" && $NASRPI_SUDO chmod 644 "$dest"
      ok "installed $dest"
    fi
    rm -f "$tmp"
  fi
}

# apt_install pkg [pkg ...] -- skips packages already present
apt_install() {
  local missing=() pkg
  for pkg in "$@"; do
    dpkg-query -W "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "already installed: $*"
    return 0
  fi
  say "Installing packages: ${missing[*]}"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    warn "DRY_RUN: would run apt-get install -y ${missing[*]}"
    return 0
  fi
  "$NASRPI_SUDO" apt-get update -qq
  "$NASRPI_SUDO" apt-get install "${missing[@]}"
}

# write_file MODE TARGET [sudo] [force]  ...content on stdin (idempotent: skips if identical)
# force="force": replace a differing file without the extra confirm prompt
# (caller already asked -- avoids double-confirmation, which ate "y" answers
# and silently left files untouched in piped sessions).
write_file() {
  local mode=$1 target=$2 usesudo=${3:-} force=${4:-} tmp target_cmp
  # in DRY_RUN with a shadow root, compare/inspect the shadow copy instead
  if [ "${DRY_RUN:-0}" = "1" ] && [ -n "${NASRPI_DRY_ROOT:-}" ]; then
    target_cmp="$NASRPI_DRY_ROOT$target"
  else
    target_cmp="$target"
  fi
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$target_cmp" ] && cmp -s "$tmp" "$target_cmp"; then
    ok "$target already up to date"
    rm -f "$tmp"; return 0
  fi
  if [ -f "$target_cmp" ] && [ "$force" != "force" ] && ! confirm "Existing $target differs. Show diff and replace?"; then
    warn "left $target untouched"
    rm -f "$tmp"; return 1
  fi
  if [ -f "$target_cmp" ]; then
    echo "--- current $target"
    if [ -r "$target_cmp" ]; then
      diff -u "$target_cmp" "$tmp" | sed 's/^/    /' || true
    elif [ -n "$usesudo" ] && [ -n "$NASRPI_SUDO" ]; then
      $NASRPI_SUDO diff -u "$target_cmp" "$tmp" | sed 's/^/    /' || true
    fi   # unreadable and no sudo available -> skip the diff display
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    if [ -n "${NASRPI_DRY_ROOT:-}" ]; then   # tests: write into a shadow tree
      mkdir -p "$NASRPI_DRY_ROOT$(dirname "$target")"
      cp "$tmp" "$NASRPI_DRY_ROOT$target"
      chmod "$mode" "$NASRPI_DRY_ROOT$target"
      warn "DRY_RUN: wrote $NASRPI_DRY_ROOT$target"
    else
      warn "DRY_RUN: would write $mode $target"
    fi
    rm -f "$tmp"; return 0
  fi
  if [ -n "${usesudo}" ]; then
    SUDO="$NASRPI_SUDO"
  else
    SUDO=""
  fi
  $SUDO mkdir -p "$(dirname "$target")"
  $SUDO cp "$tmp" "$target" && "$SUDO" chmod "$mode" "$target"
  rm -f "$tmp"
  ok "wrote $target"
}

# drify PATH -- in DRY_RUN mode map a root path into the shadow root (tests)
drify() {
  if [ "${DRY_RUN:-0}" = "1" ] && [ -n "${NASRPI_DRY_ROOT:-}" ]; then
    echo "$NASRPI_DRY_ROOT$1"
  else
    echo "$1"
  fi
}

# Edit a file with $EDITOR; fall back gracefully
edit_file() {
  local f=$1 usesudo=$2
  if [ -n "${usesudo}" ]; then
    SUDO="$NASRPI_SUDO"
  else
    SUDO=""
  fi
  $SUDO "${EDITOR:-$(command -v emacs || command -v vi)}" "$f"
}

# Ask for a destination under /media/nas/<name> for an item (remotes, mailboxes)
# derive_name "some:remote" -> some ; "acct_name" -> acct_name ; "a@b.com" -> b
derive_name() {
  local s=${1%%:*}          # strip rclone remote type separator
  s=${s%%@*}                # strip user part of e-mail
  s=${s%%.*}                # strip leading domain bits
  s=$(printf '%s' "$s" | tr -c 'A-Za-z0-9_-' '_')
  s=${s:-item}
  echo "$s"
}
