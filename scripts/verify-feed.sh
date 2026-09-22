#!/usr/bin/env bash
# =============================================================================
# verify-feed.sh — prove that a feed URL returns items, right now
#
#   ./scripts/verify-feed.sh <feed-url>
#
# Exit codes: 0 = the feed returned at least one item   1 = it did not
#
# Why this exists. The failure that actually bites is a feed which fetches
# perfectly and returns ZERO items — a rotted CSS selector, a bridge whose
# upstream page changed shape, an expired account cookie. Inside the reader
# every one of those is indistinguishable from "no new posts". Without a
# positive item count at subscribe time you find out weeks later, by noticing a
# category has been quiet. docs/source_catalog.md §7 lists the symptoms this
# is meant to catch; run it when adding a feed and again when a feed looks quiet.
#
# A bridged URL needs its &token=... in full. Copy it from the RSS-Bridge UI
# rather than by hand — a URL missing the token returns 401, which is a very
# common false alarm.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

TIMEOUT=20

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

if [ $# -lt 1 ]; then
  usage
  exit 1
fi
case "$1" in
  -h|--help) usage; exit 0 ;;
esac

URL="$1"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Warn about the single most common false alarm before making the request.
case "$URL" in
  *127.0.0.1:3000*|*localhost:3000*)
    case "$URL" in
      *token=*) ;;
      *) warn "this RSS-Bridge URL has no &token= — it will return 401"
         dim  "read the token from private/env (RSSBRIDGE_TOKEN)" ;;
    esac
    ;;
esac

CODE="$(curl -s -o "$TMP" -w '%{http_code}' --max-time "$TIMEOUT" "$URL" 2>/dev/null || true)"
[ -n "$CODE" ] || CODE="000"

if [ "$CODE" = "000" ]; then
  printf '\n  %sFAIL%s no response from %s within %ss\n\n' "$C_RED" "$C_RESET" "$URL" "$TIMEOUT"
  dim "is the service up?  ./scripts/services.sh status"
  exit 1
fi

# Item counts. `<entry` is Atom, `<item` is RSS. Both are counted with -o so a
# feed that puts several items on one line is not undercounted as one.
FORMAT="unknown"
COUNT=0
if grep -q '<feed' "$TMP" 2>/dev/null; then
  FORMAT="Atom"
  COUNT="$(grep -o '<entry' "$TMP" | wc -l | tr -d ' ')"
elif grep -q '<rss' "$TMP" 2>/dev/null; then
  FORMAT="RSS"
  COUNT="$(grep -o '<item' "$TMP" | wc -l | tr -d ' ')"
fi

# Pull the first item out so the title and date reported belong to a real
# entry rather than to the feed's own <updated>, which comes first in Atom.
# NOTE: the awk variables must not be named `open`/`close` — `close` is a
# builtin function in awk, and using it as a variable is a syntax error.
first_item() {
  awk -v opentag="$1" -v closetag="$2" '
    !inside && index($0, opentag) { inside = 1 }
    inside { print }
    inside && index($0, closetag) { exit }
  ' "$TMP"
}

FIRST=""
case "$FORMAT" in
  Atom) FIRST="$(first_item '<entry' '</entry>')" ;;
  RSS)  FIRST="$(first_item '<item' '</item>')" ;;
esac

field() {
  printf '%s' "${1-}" | grep -oE "<$2[^>]*>[^<]*" | head -n 1 | sed -E "s/<[^>]*>//" || true
}

TITLE="$(field "$FIRST" 'title')"
if [ "$FORMAT" = "Atom" ]; then
  DATE="$(field "$FIRST" 'updated')"
  [ -n "$DATE" ] || DATE="$(field "$FIRST" 'published')"
else
  DATE="$(field "$FIRST" 'pubDate')"
fi

printf '\n  %s%s%s\n' "$C_BLUE" "$URL" "$C_RESET"
printf '    %-8s %s\n' "http" "$CODE"
printf '    %-8s %s\n' "format" "$FORMAT"
printf '    %-8s %s\n' "items" "$COUNT"
[ -n "$TITLE" ] && printf '    %-8s %s\n' "first" "$(printf '%s' "$TITLE" | head -c 110)"
[ -n "$DATE" ]  && printf '    %-8s %s\n' "date" "$(printf '%s' "$DATE" | head -c 60)"
printf '\n'

if [ "$FORMAT" = "unknown" ]; then
  printf '  %sFAIL%s %s did not parse as Atom or RSS\n' "$C_RED" "$C_RESET" "$URL"
  dim "an RSS-Bridge error page is served with a 200 sometimes — check the body:"
  dim "  curl -s '$URL' | head -c 400"
  printf '\n'
  exit 1
fi

if [ "$COUNT" -eq 0 ]; then
  printf '  %sFAIL%s parsed as %s but returned 0 items\n' "$C_RED" "$C_RESET" "$FORMAT"
  dim "for a CSS-selected feed this means the selector matched nothing."
  dim "see docs/source_catalog.md §7 for the full symptom list."
  printf '\n'
  exit 1
fi

if [ -z "$TITLE" ]; then
  printf '  %sWARN%s items found but the first one has no title\n' "$C_YELLOW" "$C_RESET"
  dim "the title selector is probably too narrow. Treat this as broken."
  printf '\n'
  exit 0
fi

printf '  %sOK%s %s item(s), titles present\n\n' "$C_GREEN" "$C_RESET" "$COUNT"
exit 0
