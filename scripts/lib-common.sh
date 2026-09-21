#!/usr/bin/env bash
# =============================================================================
# lib-common.sh — shared helpers for glass_candle_tv ops scripts
#
# Sourced, never executed. Targets bash 3.2 (the version macOS ships), so:
#   - no associative arrays, no ${var,,}, no mapfile
# =============================================================================

set -euo pipefail

BGC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Everything personal lives under private/ — config, the feed database, cloned
# apps, generated service configs, logs and backups. One gitignore rule covers
# the whole subtree, so "is this safe to publish" is answered by one question:
# is it under private/ or not.
BGC_PRIVATE="$BGC_ROOT/private"
ENV_FILE="$BGC_PRIVATE/env"
ENV_EXAMPLE="$BGC_ROOT/.env.example"
APPS_DIR="$BGC_PRIVATE/apps"
ETC_DIR="$BGC_PRIVATE/etc"
RUN_DIR="$BGC_PRIVATE/run"
LOGS_DIR="$BGC_PRIVATE/logs"
BACKUPS_DIR="$BGC_PRIVATE/backups"

FRESHRSS_DIR="$APPS_DIR/FreshRSS"
RSSBRIDGE_DIR="$APPS_DIR/rss-bridge"

# launchd labels. Must match scripts/install.sh and scripts/services.sh.
LAUNCHD_PREFIX="com.afrogenesurvive.glass-candle-tv"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
dim()  { printf '%s     %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()  { printf '%s error:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Reading private/env
# -----------------------------------------------------------------------------
# Deliberately NOT `source`-ing the file: a value containing a backtick, $(), or
# an unbalanced quote would execute. These helpers parse it as data.
#
# Known limitation: a `#` inside an unquoted value is treated as a comment
# marker when preceded by whitespace. That is the standard convention for this
# file format.
# -----------------------------------------------------------------------------

get_env() {
  local key="$1" default="${2-}" line val
  if [ ! -f "$ENV_FILE" ]; then
    printf '%s' "$default"
    return 0
  fi
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" | tail -n 1 || true)"
  if [ -z "$line" ]; then
    printf '%s' "$default"
    return 0
  fi
  val="${line#*=}"

  # 1. Trim leading whitespace only.
  val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//')"

  # 2. Leading '#' means the entire value is a comment. This is the shape of
  #    every placeholder in .env.example (`VAR=        # REQUIRED`), and it must
  #    read as EMPTY, not as the literal text "# REQUIRED".
  case "$val" in
    "#"*) printf '%s' "$default"; return 0 ;;
  esac

  # 3. Quoted values are literal — a '#' inside quotes is data, not a comment.
  case "$val" in
    \"*) val="${val#\"}";  val="${val%%\"*}";  printf '%s' "$val"; return 0 ;;
    \'*) val="${val#\'}";  val="${val%%\'*}";  printf '%s' "$val"; return 0 ;;
  esac

  # 4. Unquoted: drop a trailing " #comment", then trim trailing whitespace.
  #    The whitespace requirement keeps values like `a#b` intact.
  #    POSIX BRE only — no \+ — so macOS sed behaves the same as GNU sed.
  val="$(printf '%s' "$val" | sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/[[:space:]]*$//')"
  printf '%s' "$val"
}

require_env_file() {
  [ -f "$ENV_FILE" ] || die "no config at private/env
       Create it:  cp .env.example private/env   (then fill it in)
       Or let the installer do it:  ./scripts/install.sh"
}

require_private_dir() {
  [ -d "$BGC_PRIVATE" ] || die "private/ is missing.  Run: ./scripts/install.sh"
}

# require_vars VAR [VAR...] — fail listing every missing var, not just the first.
require_vars() {
  local missing='' v val
  for v in "$@"; do
    val="$(get_env "$v")"
    if [ -z "$val" ]; then
      missing="${missing}${v} "
    fi
  done
  if [ -n "$missing" ]; then
    die "these required values are empty in private/env: ${missing}
       See docs/inputs_required.md for how to obtain each one."
  fi
}

# -----------------------------------------------------------------------------
# Toolchain
# -----------------------------------------------------------------------------
require_brew() {
  command -v brew >/dev/null 2>&1 || die "Homebrew not found.
       Install it from https://brew.sh and re-run."
}

require_php() {
  command -v php >/dev/null 2>&1 || die "php not found on PATH.
       Install it:  brew install php"
}

PHP_BIN="$(command -v php 2>/dev/null || true)"
PHP_VER=""
if [ -n "$PHP_BIN" ]; then
  PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
fi

# How many worker processes the built-in PHP server forks.
# The default is 1, which means a single slow request (a feed refresh triggered
# from the UI) blocks the whole interface. Four is ample for one person and still
# trivially light on a laptop.
php_cli_workers() { get_env PHP_CLI_SERVER_WORKERS 4; }

# -----------------------------------------------------------------------------
# launchd — user-level agents, so nothing here needs sudo
# -----------------------------------------------------------------------------
plist_path() { printf '%s/%s.%s.plist' "$LAUNCH_AGENTS_DIR" "$LAUNCHD_PREFIX" "$1"; }
label_for()  { printf '%s.%s' "$LAUNCHD_PREFIX" "$1"; }

agent_loaded() {
  launchctl print "gui/$(id -u)/$(label_for "$1")" >/dev/null 2>&1
}

agent_state() {
  # running | loaded | not-loaded
  local label; label="$(label_for "$1")"
  if ! launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    printf 'not-loaded'; return
  fi
  if launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -qE 'state = running'; then
    printf 'running'
  else
    printf 'loaded'
  fi
}

bootout_agent() {
  local label; label="$(label_for "$1")"
  if agent_loaded "$1"; then
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  fi
}

bootstrap_agent() {
  local name="$1" plist; plist="$(plist_path "$name")"
  [ -f "$plist" ] || die "missing launch agent plist: $plist"
  bootout_agent "$name"
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null \
    || die "could not load launch agent '$name'
       Try manually:  launchctl bootstrap gui/$(id -u) '$plist'"
  launchctl enable "gui/$(id -u)/$(label_for "$name")" >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# HTTP / ports
# -----------------------------------------------------------------------------
# Returns the HTTP status code, or '000' if the request could not be made.
#
# NOTE: on failure curl BOTH prints `000` (the %{http_code} placeholder) AND
# exits non-zero. Writing `... || printf '000'` therefore appends a second one
# and yields `000000`, which then fails every `= "000"` comparison downstream
# and makes a working service look dead. Capture, then normalise.
http_code() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-5}" "$1" 2>/dev/null)" || true
  [ -n "$code" ] || code="000"
  printf '%s' "$code"
}

port_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

port_holder() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $1" (pid "$2")"}' | head -1
}

# -----------------------------------------------------------------------------
# Misc
# -----------------------------------------------------------------------------
timestamp() { date "+%Y%m%d-%H%M%S"; }

# Expand a leading ~ so paths from .env work in [ -d ] tests and mkdir.
expand_path() {
  case "$1" in
    "~/"*) printf '%s' "$HOME/${1#\~/}" ;;
    "~")   printf '%s' "$HOME" ;;
    *)     printf '%s' "$1" ;;
  esac
}

confirm() {
  # confirm "question" — returns 0 on yes. Non-interactive input fails safe.
  local reply
  printf '%s [y/N] ' "$1"
  read -r reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

human_bytes() {
  awk -v b="$1" 'BEGIN {
    split("B KB MB GB TB", u, " ")
    i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

freshrss_port()  { get_env FRESHRSS_PORT 8080; }
rssbridge_port() { get_env RSSBRIDGE_PORT 3000; }

# The API base the menu bar app expects. Kept in one place so the app's config
# and the server's URL can never drift apart.
freshrss_api_url() {
  printf 'http://127.0.0.1:%s/api/greader.php' "$(freshrss_port)"
}
