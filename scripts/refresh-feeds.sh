#!/usr/bin/env bash
# =============================================================================
# refresh-feeds.sh — fetch new articles for every feed
#
# Run by launchd on the schedule derived from CRON_MIN in private/env
# (see scripts/services.sh). This is the native equivalent of the cron daemon
# that the FreshRSS Docker image runs when CRON_MIN is set — without it, nothing
# ever refreshes, and the instance looks perfectly healthy while going stale.
#
#   ./scripts/refresh-feeds.sh          # refresh, log the result
#   ./scripts/refresh-feeds.sh --quiet  # no console output (what launchd uses)
#
# Exit codes: 0 = refreshed (or nothing to do), 1 = the refresh failed.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

QUIET=0
[ "${1-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

if [ ! -d "$FRESHRSS_DIR" ]; then
  say "FreshRSS is not installed at $FRESHRSS_DIR — nothing to refresh."
  exit 0
fi

mkdir -p "$LOGS_DIR"
LOG="$LOGS_DIR/refresh.log"

# Trim the log before appending. A twice-hourly job with verbose output would
# otherwise grow without bound on a machine that only has a few GB free.
if [ -f "$LOG" ]; then
  LOG_BYTES="$(wc -c < "$LOG" | tr -d ' ')"
  if [ "$LOG_BYTES" -gt 1048576 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    printf '%s\n' "--- log trimmed at $(date '+%Y-%m-%d %H:%M:%S') ---" >> "$LOG"
  fi
fi

FRESHRSS_USER="$(get_env ADMIN_USER admin)"
PHP="$(command -v php || true)"

if [ -z "$PHP" ]; then
  {
    printf '%s refresh FAILED: php not found on PATH\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '  launchd runs agents with a minimal environment; PATH is set in the\n'
    printf '  plist (see scripts/services.sh). If php moved, reload the agent.\n'
  } >> "$LOG"
  say "php not found on PATH."
  exit 1
fi

# FreshRSS has two entry points. The per-user CLI is the current one; the
# application script is the older cron target that refreshes every user. Prefer
# the CLI when present, fall back so the job survives either layout.
ENTRY=""
if [ -f "$FRESHRSS_DIR/cli/actualize-user.php" ]; then
  ENTRY="cli"
elif [ -f "$FRESHRSS_DIR/app/actualize_script.php" ]; then
  ENTRY="app"
fi

if [ -z "$ENTRY" ]; then
  {
    printf '%s refresh FAILED: no refresh entry point found\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '  Looked for cli/actualize-user.php and app/actualize_script.php under %s\n' "$FRESHRSS_DIR"
  } >> "$LOG"
  say "No FreshRSS refresh entry point found — the clone may be incomplete."
  exit 1
fi

STARTED="$(date '+%Y-%m-%d %H:%M:%S')"
OUTPUT=""
STATUS=0

if [ "$ENTRY" = "cli" ]; then
  OUTPUT="$("$PHP" "$FRESHRSS_DIR/cli/actualize-user.php" --user "$FRESHRSS_USER" 2>&1)" || STATUS=$?
else
  OUTPUT="$("$PHP" "$FRESHRSS_DIR/app/actualize_script.php" 2>&1)" || STATUS=$?
fi

# The job runs from launchd, so this log is the only record of what happened.
{
  printf '=== %s  (entry: %s, user: %s) ===\n' "$STARTED" "$ENTRY" "$FRESHRSS_USER"
  [ -n "$OUTPUT" ] && printf '%s\n' "$OUTPUT"
  if [ "$STATUS" -eq 0 ]; then
    printf 'exit 0 — ok\n'
  else
    printf 'exit %s — FAILED\n' "$STATUS"
  fi
  printf '=== finished %s ===\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} >> "$LOG"

if [ "$STATUS" -eq 0 ]; then
  say "Feed refresh complete."
else
  say "Feed refresh FAILED (exit $STATUS). See $LOG"
fi
exit "$STATUS"
