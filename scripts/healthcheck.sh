#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — one-shot status of the whole stack
#
#   ./scripts/healthcheck.sh
#   ./scripts/healthcheck.sh --quiet    # only failures
#
# Exit codes:  0 = all good (warnings allowed)   1 = at least one FAIL
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

QUIET=0
case "${1-}" in
  --quiet|-q) QUIET=1 ;;
  -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) die "unknown argument: $1" ;;
esac

FAILS=0
WARNS=0

pass() { [ "$QUIET" -eq 1 ] || printf '%s  PASS%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() { printf '%s  FAIL%s %s\n' "$C_RED" "$C_RESET" "$*"; FAILS=$((FAILS + 1)); }
note() { printf '%s  WARN%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; WARNS=$((WARNS + 1)); }
skip() { [ "$QUIET" -eq 1 ] || printf '%s  ----%s %s\n' "$C_DIM" "$C_RESET" "$*"; }

http_code() { # http_code URL [timeout]
  curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-5}" "$1" 2>/dev/null || printf '000'
}

printf '\n%sblack_glass_candle — healthcheck%s\n\n' "$C_BLUE" "$C_RESET"

# -----------------------------------------------------------------------------
# 1. Prerequisites
# -----------------------------------------------------------------------------
info "prerequisites"

if [ ! -f "$ENV_FILE" ]; then
  fail ".env missing — Fix: cp .env.example .env"
  printf '\n%sNothing else can be checked without .env.%s\n\n' "$C_RED" "$C_RESET"
  exit 1
fi
pass ".env present"

if ! command -v docker >/dev/null 2>&1; then
  fail "docker not on PATH — install Docker Desktop / OrbStack / colima"
  printf '\n'
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  fail "Docker daemon not running — start Docker Desktop"
  printf '\n'
  exit 1
fi
pass "docker daemon reachable"

# The single most common way to leak credentials is a .gitignore regression.
if git -C "$BGC_ROOT" check-ignore -q --no-index .env 2>/dev/null; then
  pass ".env is gitignored"
else
  fail ".env is NOT gitignored — fix .gitignore before committing anything"
fi

# -----------------------------------------------------------------------------
# 2. Configuration sanity
# -----------------------------------------------------------------------------
info "configuration"

CRON_MIN="$(get_env CRON_MIN)"
if [ -z "$CRON_MIN" ]; then
  fail "CRON_MIN is empty — feeds will NEVER refresh"
  dim "set CRON_MIN=13,43 in .env and run: docker compose up -d"
else
  pass "CRON_MIN=$CRON_MIN"
fi

TZ_VAL="$(get_env TZ)"
if [ -z "$TZ_VAL" ] || [ "$TZ_VAL" = "UTC" ]; then
  note "TZ is unset or UTC — feed timestamps and 'today' filters may be off"
else
  pass "TZ=$TZ_VAL"
fi

ALLOW="$(get_env INTERNAL_HOST_ALLOWLIST)"
case "$ALLOW" in
  *rss-bridge*) pass "INTERNAL_HOST_ALLOWLIST permits rss-bridge" ;;
  *)            note "INTERNAL_HOST_ALLOWLIST does not mention rss-bridge — bridged feeds will fail to fetch" ;;
esac

ADDR="$(get_env BIND_ADDR 127.0.0.1)"
if [ "$ADDR" = "0.0.0.0" ]; then
  note "BIND_ADDR=0.0.0.0 — the login page is reachable from your whole network"
else
  pass "BIND_ADDR=$ADDR (loopback only)"
fi

# -----------------------------------------------------------------------------
# 3. Containers
# -----------------------------------------------------------------------------
info "containers"

for svc in freshrss rss-bridge; do
  state="$(compose ps --format '{{.Service}} {{.State}} {{.Status}}' 2>/dev/null | grep "^${svc} " || true)"
  if [ -z "$state" ]; then
    fail "$svc is not created — run: docker compose up -d"
  elif printf '%s' "$state" | grep -q "(healthy)"; then
    pass "$svc healthy"
  elif printf '%s' "$state" | grep -q "Up"; then
    note "$svc up but not yet healthy — $(printf '%s' "$state" | cut -d' ' -f3-)"
  else
    fail "$svc not running — $(printf '%s' "$state" | cut -d' ' -f3-)"
  fi
done

# -----------------------------------------------------------------------------
# 4. Endpoints
# -----------------------------------------------------------------------------
info "endpoints"

FR_PORT="$(get_env FRESHRSS_PORT 8080)"
RB_PORT="$(get_env RSSBRIDGE_PORT 3000)"

FR_CODE="$(http_code "http://127.0.0.1:${FR_PORT}/")"
case "$FR_CODE" in
  200|302) pass "FreshRSS responds on :${FR_PORT} (HTTP $FR_CODE)" ;;
  000)     fail "FreshRSS not reachable on :${FR_PORT}" ;;
  *)       fail "FreshRSS returned HTTP $FR_CODE on :${FR_PORT}" ;;
esac

RB_CODE="$(http_code "http://127.0.0.1:${RB_PORT}/")"
case "$RB_CODE" in
  200|302) pass "RSS-Bridge responds on :${RB_PORT} (HTTP $RB_CODE)" ;;
  000)     fail "RSS-Bridge not reachable on :${RB_PORT}" ;;
  *)       fail "RSS-Bridge returned HTTP $RB_CODE on :${RB_PORT}" ;;
esac

# Token auth must be ON, and must actually reject a bad token. A bridge that
# answers 200 to a wrong token is an open URL fetcher.
TOKEN="$(get_env RSSBRIDGE_TOKEN)"
if [ -z "$TOKEN" ]; then
  note "RSSBRIDGE_TOKEN empty — cannot verify bridge authentication"
elif [ "$RB_CODE" = "000" ]; then
  skip "RSS-Bridge unreachable — skipping token check"
else
  GOOD="$(http_code "http://127.0.0.1:${RB_PORT}/?action=display&bridge=HackerNewsBridge&format=Atom&token=${TOKEN}" 10)"
  BAD="$(http_code "http://127.0.0.1:${RB_PORT}/?action=display&bridge=HackerNewsBridge&format=Atom&token=definitely-wrong" 10)"
  if [ "$BAD" = "200" ]; then
    fail "RSS-Bridge ACCEPTED a wrong token — authentication is disabled"
  elif [ "$GOOD" = "200" ]; then
    pass "RSS-Bridge token auth working (good=$GOOD bad=$BAD)"
  else
    note "RSS-Bridge good-token request returned $GOOD (bad=$BAD) — bridge may be rate-limited"
  fi
fi

# FreshRSS API: 503 here almost always means the Authentication toggle is off.
API_BASE_URL="$(get_env MENUBAR_API_BASE_URL)"
if [ -z "$API_BASE_URL" ]; then
  note "MENUBAR_API_BASE_URL not set — cannot check the API"
else
  CODE="$(http_code "${API_BASE_URL%/}/" 10)"
  case "$CODE" in
    200) pass "FreshRSS API endpoint reachable" ;;
    503) fail "FreshRSS API returned 503 — enable 'Allow API access' under Authentication" ;;
    000) fail "FreshRSS API not reachable at $API_BASE_URL" ;;
    *)   note "FreshRSS API returned HTTP $CODE" ;;
  esac
fi

# -----------------------------------------------------------------------------
# 5. Storage
# -----------------------------------------------------------------------------
info "storage"

VOL="black_glass_candle_freshrss_data"
SIZE_BYTES="$(docker run --rm -v "${VOL}:/d:ro" alpine:3 du -sb /d 2>/dev/null | awk '{print $1}' || true)"
if [ -n "$SIZE_BYTES" ]; then
  pass "feed database volume: $(human_bytes "$SIZE_BYTES")"
else
  skip "could not measure volume $VOL (not created yet?)"
fi

BACKUP_DIR="$(expand_path "$(get_env BACKUP_DIR "$HOME/Backups/black_glass_candle")")"
if [ -d "$BACKUP_DIR" ]; then
  COUNT="$(find "$BACKUP_DIR" -name 'freshrss-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$COUNT" -gt 0 ]; then
    pass "$COUNT backup(s) in $BACKUP_DIR"
  else
    note "no backups yet in $BACKUP_DIR — run ./scripts/backup.sh"
  fi
else
  note "no backup directory at $BACKUP_DIR — run ./scripts/backup.sh"
fi

# -----------------------------------------------------------------------------
# 6. Menubar app
# -----------------------------------------------------------------------------
info "menu bar app"

APP="$BGC_ROOT/build/black_glass_candle.app"
if [ -d "$APP" ]; then
  pass "app bundle built"
else
  note "app not built yet — run ./scripts/build.sh"
fi

if security find-generic-password -s "black_glass_candle" -a "api-password" >/dev/null 2>&1; then
  pass "API password present in Keychain"
else
  note "API password not in Keychain — run ./scripts/seed_menubar_config.sh"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n'
if [ "$FAILS" -gt 0 ]; then
  printf '%s%d failure(s), %d warning(s)%s\n' "$C_RED" "$FAILS" "$WARNS" "$C_RESET"
  printf 'See docs/operations.md §4 for the decision table.\n\n'
  exit 1
fi
printf '%sall checks passed (%d warning(s))%s\n\n' "$C_GREEN" "$WARNS" "$C_RESET"
exit 0
