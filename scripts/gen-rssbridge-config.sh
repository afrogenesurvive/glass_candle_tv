#!/usr/bin/env bash
# =============================================================================
# gen-rssbridge-config.sh
#
# Generates rss-bridge-config/config.ini.php from .env.
#
#   ./scripts/gen-rssbridge-config.sh            # write config
#   ./scripts/gen-rssbridge-config.sh --dry-run  # print to stdout instead
#
# The generated file holds a live token, so it is written 0600 and is
# gitignored alongside .env.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

DRY_RUN=0
case "${1-}" in
  --dry-run|-n) DRY_RUN=1 ;;
  -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) die "unknown argument: $1" ;;
esac

require_env_file
require_vars RSSBRIDGE_TOKEN

TOKEN="$(get_env RSSBRIDGE_TOKEN)"
BRIDGES="$(get_env RSSBRIDGE_ENABLED_BRIDGES 'CssSelectorBridge,RedditBridge,HackerNewsBridge,LemmyBridge,BearBlogBridge,GitHubBridge,FeedMergeBridge,FilterBridge,FeedReducerBridge')"
CACHE_DURATION="$(get_env RSSBRIDGE_CACHE_DURATION 3600)"

OUT="$BGC_ROOT/rss-bridge-config/config.ini.php"

emit() {
  printf '%s\n' '; <?php exit; ?> DO NOT REMOVE THIS LINE'
  printf '%s\n' '; ---------------------------------------------------------------------------'
  printf '%s\n' '; GENERATED FILE - do not edit.'
  printf '%s\n' '; Source of truth: .env   Regenerate: ./scripts/gen-rssbridge-config.sh'
  printf '; Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '%s\n' '; ---------------------------------------------------------------------------'
  printf '\n'
  printf '%s\n' '[authentication]'
  printf '%s\n' '; Every feed URL must carry &token=<this value>.'
  printf '%s\n' '; Without it this container is an open, unauthenticated URL fetcher.'
  printf 'token = "%s"\n' "$TOKEN"
  printf '\n'
  printf '%s\n' '[error]'
  printf '%s\n' '; "http" keeps transient bridge failures out of the feed as fake articles.'
  printf '%s\n' 'output = "http"'
  printf '%s\n' 'report_limit = 3'
  printf '\n'
  printf '%s\n' '[cache]'
  printf '%s\n' '; Long enough that FreshRSS can refresh twice an hour without ever'
  printf '%s\n' '; causing a redundant upstream request.'
  printf '%s\n' 'type = "file"'
  printf 'duration = %s\n' "$CACHE_DURATION"
  printf '\n'
  printf '%s\n' '; Bridge allowlist. Least privilege: several of the 400+ upstream bridges'
  printf '%s\n' '; make outbound requests on your behalf.'
  # NOTE: `printf '%s\n'` (with the newline) is required. With `printf '%s'` the
  # final item has no line terminator, `read` returns non-zero at EOF, and the
  # loop body never runs for it — silently dropping the last bridge.
  printf '%s\n' "$BRIDGES" | tr ',' '\n' | while IFS= read -r b; do
    b="$(printf '%s' "$b" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$b" ] || continue
    printf 'enabled_bridges[] = %s\n' "$b"
  done
  printf '\n'
  printf '%s\n' '; Custom bridges placed in this directory are picked up automatically.'
}

if [ "$DRY_RUN" -eq 1 ]; then
  info "dry run — would write $OUT"
  emit | sed "s/$TOKEN/<REDACTED>/g"
  exit 0
fi

mkdir -p "$(dirname "$OUT")"
# Write via a temp file in the same directory so a failure cannot leave a
# half-written config behind.
TMP="$(mktemp "$(dirname "$OUT")/.config.ini.php.XXXXXX")"
emit > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$OUT"

ok "wrote $OUT"
dim "token is redacted in this output on purpose"

BRIDGE_COUNT="$(printf '%s\n' "$BRIDGES" | tr ',' '\n' | grep -c '[^[:space:]]' || true)"
ok "$BRIDGE_COUNT bridge(s) enabled"

cat <<'NEXT'

  Restart for changes to take effect:

    docker compose restart rss-bridge

  Verify token auth is actually on:

    curl -s "http://127.0.0.1:3000/?action=display&bridge=HackerNewsBridge&format=Atom&token=$RSSBRIDGE_TOKEN" | head
    curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:3000/?action=display&bridge=HackerNewsBridge&format=Atom&token=wrong"

  The first should return Atom. The second should NOT return 200.
NEXT
