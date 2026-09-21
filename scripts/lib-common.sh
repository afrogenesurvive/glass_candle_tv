#!/usr/bin/env bash
# =============================================================================
# lib-common.sh — shared helpers for black_glass_candle ops scripts
#
# Sourced, never executed. Targets bash 3.2 (the version macOS ships), so:
#   - no associative arrays, no ${var,,}, no mapfile
# =============================================================================

set -euo pipefail

BGC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$BGC_ROOT/.env"
ENV_EXAMPLE="$BGC_ROOT/.env.example"
COMPOSE_FILE="$BGC_ROOT/docker-compose.yml"

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
# Reading .env
# -----------------------------------------------------------------------------
# Deliberately NOT `source .env`: a value containing a backtick, $(), or an
# unbalanced quote would execute. These helpers parse the file as data.
#
# Known limitation: a `#` inside an unquoted value is treated as a comment
# marker when preceded by whitespace. That is the standard .env convention and
# matches what docker compose does.
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
  [ -f "$ENV_FILE" ] || die ".env not found.  Fix: cp .env.example .env  (then fill it in)"
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
    die "these required variables are empty in .env: ${missing}
       See docs/inputs_required.md for how to obtain each one."
  fi
}

# -----------------------------------------------------------------------------
# Docker
# -----------------------------------------------------------------------------
require_docker() {
  command -v docker >/dev/null 2>&1 \
    || die "docker not found on PATH.
       Install Docker Desktop, OrbStack, or colima, then re-run.
       See README.md > Prerequisites."
  docker compose version >/dev/null 2>&1 \
    || die "docker is present but 'docker compose' (v2) is not.
       The v1 'docker-compose' command is not supported by these scripts."
  docker info >/dev/null 2>&1 \
    || die "the Docker daemon is not running. Start Docker Desktop and retry."
}

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

# Is the freshrss container up?
freshrss_running() {
  [ "$(compose ps --status running --services 2>/dev/null | grep -c '^freshrss$' || true)" -gt 0 ]
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
