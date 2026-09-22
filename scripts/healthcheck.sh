#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — one-shot status of the whole stack
#
#   ./scripts/healthcheck.sh
#   ./scripts/healthcheck.sh --quiet    # only problems
#
# Exit codes:  0 = no failures (warnings allowed)   1 = at least one FAIL
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

printf '\n%sglass_candle_tv — healthcheck%s\n\n' "$C_BLUE" "$C_RESET"

# -----------------------------------------------------------------------------
# 1. Layout and privacy
# -----------------------------------------------------------------------------
info "layout"

if [ -d "$BGC_PRIVATE" ]; then
  pass "data directory present — $BGC_PRIVATE"
else
  fail "data directory is missing: $BGC_PRIVATE — run: ./scripts/install.sh"
  printf '\n'
  exit 1
fi

# The data must not sit inside a macOS-protected folder. The refresh agent runs
# from launchd, and a launchd-spawned /bin/bash has no Files-and-Folders grant
# for ~/Documents, ~/Desktop or ~/Downloads: the script cannot even be read, the
# job dies with exit 126, and the symptom is a reader that quietly stops
# updating. Verified by measurement, not assumed — see lib-common.sh.
case "$BGC_PRIVATE" in
  "$HOME/Documents"/*|"$HOME/Desktop"/*|"$HOME/Downloads"/*)
    fail "the data directory is inside a macOS-protected folder — launchd cannot read it"
    dim "move it out — see 'Where the data lives' in docs/operations.md — then re-run"
    dim "./scripts/services.sh install"
    ;;
  *)
    pass "data directory is outside the macOS-protected folders"
    ;;
esac

# The repo itself must stay free of personal state. `private/` is still covered
# by .gitignore as a safety net, but the live data is no longer there, so what is
# worth asserting is that no second copy has crept back in.
if [ -d "$BGC_ROOT/private" ]; then
  note "a private/ directory exists inside the repo: $BGC_ROOT/private"
  dim "it is not the live data and launchd cannot read it — delete it when you are sure"
fi

if [ -f "$ENV_FILE" ]; then
  pass "config present ($ENV_FILE, $(stat -f '%Sp' "$ENV_FILE" 2>/dev/null || echo '?'))"
else
  fail "config is missing: $ENV_FILE — run: cp .env.example \"$ENV_FILE\""
fi

# The single most important security property: the feed database must not be
# reachable over HTTP. Assert the invariant, not just the intent.
if [ -d "$FRESHRSS_DIR/data" ]; then
  case "$FRESHRSS_DIR/data" in
    "$FRESHRSS_DIR/p"/*) fail "FreshRSS data/ is INSIDE the web docroot — it is being served" ;;
    *)                   pass "FreshRSS data/ is outside the web docroot" ;;
  esac
else
  skip "FreshRSS data/ does not exist yet"
fi

# -----------------------------------------------------------------------------
# 2. Configuration
# -----------------------------------------------------------------------------
info "configuration"

if [ -f "$ENV_FILE" ]; then
  missing=''
  for v in ADMIN_API_PASSWORD RSSBRIDGE_TOKEN; do
    [ -n "$(get_env "$v")" ] || missing="${missing}${v} "
  done
  if [ -n "$missing" ]; then
    fail "empty API secrets in private/env: ${missing}"
  else
    pass "API secrets present"
  fi

  if [ -z "$(get_env ADMIN_PASSWORD)" ]; then
    note "ADMIN_PASSWORD is empty — the admin account has not been created"
    dim "set it in private/env and re-run ./scripts/install.sh"
  else
    pass "ADMIN_PASSWORD set"
  fi

  if [ -z "$(get_env CRON_MIN)" ]; then
    # Not a failure natively. services.sh falls back to StartInterval 1800, so
    # an empty CRON_MIN degrades the schedule to every 30 minutes rather than
    # removing it — the Docker stack's behaviour was the opposite.
    note "CRON_MIN is empty — falling back to a 30-minute interval"
    dim "set it in private/env, then re-run ./scripts/services.sh install"
  else
    pass "CRON_MIN=$(get_env CRON_MIN) (feeds refresh on this schedule)"
  fi

  tz_val="$(get_env TZ)"
  if [ -z "$tz_val" ] || [ "$tz_val" = "UTC" ]; then
    note "TZ is unset or UTC — feed timestamps may be shifted"
  else
    pass "TZ=$tz_val"
  fi
fi

# -----------------------------------------------------------------------------
# 3. Toolchain and services
# -----------------------------------------------------------------------------
info "services"

if command -v php >/dev/null 2>&1; then
  pass "PHP $PHP_VER"
else
  fail "php not on PATH"
fi

# The refresh agent executes a COPY of these scripts from the data directory, so
# the code that runs on a schedule can be older than the code in the repo. That
# is the most confusing failure this layout can produce — "I changed it and
# nothing happened" — so it is checked rather than trusted.
for f in $AGENT_FILES; do
  if [ ! -f "$AGENT_DIR/$f" ]; then
    fail "agent copy missing: $AGENT_DIR/$f — run ./scripts/services.sh install"
  elif ! cmp -s "$BGC_ROOT/scripts/$f" "$AGENT_DIR/$f"; then
    note "stale agent copy: $f — run ./scripts/services.sh install to deploy it"
  fi
done

for svc in freshrss rssbridge refresh; do
  state="$(agent_state "$svc")"
  case "$state" in
    running)    pass "$svc: running" ;;
    loaded)
      if [ "$svc" != "refresh" ]; then
        note "$svc: loaded but not running"
        continue
      fi
      # A calendar job is legitimately idle between firings, so "loaded" on its
      # own proves nothing — reporting PASS here is how a job that fails every
      # single run stays invisible. launchd's recorded exit status is the
      # evidence: non-zero means it fired and died before the script could run.
      last_exit="$(agent_last_exit refresh)"
      if [ -n "$last_exit" ] && [ "$last_exit" -ne 0 ] 2>/dev/null; then
        fail "refresh: job is failing (last exit $last_exit) — feeds are NOT refreshing"
        dim "see private/logs/refresh-stderr.log"
      else
        pass "$svc: scheduled"
      fi
      ;;
    not-loaded) fail "$svc: not loaded — run ./scripts/services.sh install" ;;
  esac
done

# -----------------------------------------------------------------------------
# 4. Endpoints
# -----------------------------------------------------------------------------
info "endpoints"

FR_PORT="$(freshrss_port)"
RB_PORT="$(rssbridge_port)"

for spec in "FreshRSS:$FR_PORT:$FRESHRSS_DIR/p" "RSS-Bridge:$RB_PORT:$RSSBRIDGE_DIR"; do
  name="${spec%%:*}"; rest="${spec#*:}"; port="${rest%%:*}"; docroot="${rest#*:}"

  if [ ! -d "$docroot" ]; then
    fail "$name: docroot missing ($docroot) — not cloned?"
    continue
  fi
  if ! port_listening "$port"; then
    fail "$name: nothing listening on :$port"
    continue
  fi

  code="$(http_code "http://127.0.0.1:$port/" 10)"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    pass "$name answering on :$port (HTTP $code)"
  elif [ "$code" = "401" ]; then
    # Not a problem — it is the strongest signal available: the service is up
    # AND token authentication is being enforced.
    pass "$name answering on :$port (HTTP 401 — token auth enforced)"
  elif [ "$code" = "000" ]; then
    fail "$name: port open but no HTTP response"
  else
    note "$name returned HTTP $code on :$port"
  fi
done

# Token auth must be ON and must actually reject a wrong token. A bridge that
# answers 200 to a bad token is an open URL fetcher for anything on this machine.
TOKEN="$(get_env RSSBRIDGE_TOKEN)"
if [ -z "$TOKEN" ]; then
  note "RSSBRIDGE_TOKEN empty — cannot verify bridge auth"
elif ! port_listening "$RB_PORT"; then
  skip "RSS-Bridge unreachable — skipping token check"
else
  # A bridge that definitely ships with RSS-Bridge, so a 404 cannot be mistaken
  # for "auth disabled". An unknown bridge name 404s *before* the token check
  # runs, which would make this test unable to fail.
  PROBE_BRIDGE="CssSelectorBridge"
  GOOD="$(http_code "http://127.0.0.1:$RB_PORT/?action=display&bridge=$PROBE_BRIDGE&format=Atom&token=${TOKEN}" 20)"
  BAD="$(http_code "http://127.0.0.1:$RB_PORT/?action=display&bridge=$PROBE_BRIDGE&format=Atom&token=definitely-wrong" 20)"
  if [ "$BAD" = "200" ]; then
    fail "RSS-Bridge ACCEPTED a wrong token — authentication is NOT being enforced"
    dim "most likely cause: config.ini.php is not in the RSS-Bridge root directory"
    dim "regenerate with: ./scripts/gen-configs.sh"
  elif [ "$BAD" = "401" ] || [ "$BAD" = "403" ]; then
    pass "RSS-Bridge token auth enforced (bad token -> $BAD)"
  else
    note "token check inconclusive: bad token returned $BAD (expected 401/403)"
  fi
fi

# FreshRSS API. Before an account exists this is expected to fail; that is
# different from it being broken.
API_URL="$(freshrss_api_url)"
if [ ! -d "$FRESHRSS_DIR/data/users" ]; then
  skip "FreshRSS API: no user yet — complete setup in the browser first"
else
  # Probe a real API route. The bare endpoint is not a usable probe: `/` has too
  # few path segments, so FreshRSS answers 400 before it ever consults the
  # api_enabled flag — which made this check report the same thing whether the API
  # was on, off, or broken.
  #
  #   /reader/api/0/token  ->  401  API enabled; the request carried no credential
  #                            503  API disabled ("Allow API access" is off)
  #                            200  API enabled and answering anonymous requests
  CODE="$(http_code "$API_URL/reader/api/0/token" 10)"
  case "$CODE" in
    401|403) pass "FreshRSS API enabled (unauthenticated request rejected with $CODE)" ;;
    200)     pass "FreshRSS API reachable" ;;
    503)     fail "FreshRSS API returned 503 — enable 'Allow API access', or run: php cli/reconfigure.php --api-enabled" ;;
    400)     fail "FreshRSS API returned 400 for a valid route — unexpected" ;;
    000)     fail "FreshRSS API not reachable at $API_URL" ;;
    *)       note "FreshRSS API returned HTTP $CODE" ;;
  esac
fi

# -----------------------------------------------------------------------------
# 5. Refresh job and backups
# -----------------------------------------------------------------------------
info "maintenance"

# refresh.log is written by refresh-feeds.sh itself, so its absence means the
# script never got as far as its own first line. launchd capturing an error in
# refresh-stderr.log instead is a different — and much more serious — situation:
# the job is firing and dying. Reporting both as "has not run yet" is what makes
# a permanently dead refresh job look like a quiet news week.
if [ -f "$LOGS_DIR/refresh.log" ]; then
  # `grep -c` prints 0 AND exits non-zero when there are no matches, so the
  # familiar `... || echo 0` idiom produces "00" and breaks the numeric test
  # below. Capture, then normalise — same trap as http_code() in lib-common.sh.
  ok_count="$(grep -c 'exit 0 — ok' "$LOGS_DIR/refresh.log" 2>/dev/null)" || true
  [ -n "$ok_count" ] || ok_count="0"
  if [ "$ok_count" -gt 0 ]; then
    pass "feed refresh has run successfully ($ok_count time(s) logged)"
  else
    note "refresh has run but never succeeded"
    dim "see $LOGS_DIR/refresh.log"
  fi
elif [ -s "$LOGS_DIR/refresh-stderr.log" ]; then
  fail "refresh has never reached the script — launchd cannot start it"
  dim "$LOGS_DIR/refresh-stderr.log holds the errors"
  dim "'Operation not permitted' there means launchd cannot read the script:"
  dim "re-run ./scripts/services.sh install to stage it into $AGENT_DIR"
else
  note "feed refresh has not run yet — see $LOGS_DIR/refresh.log"
fi

ARCHIVE_DIR="$(backups_dir)"
if [ -d "$ARCHIVE_DIR" ]; then
  count="$(find "$ARCHIVE_DIR" -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$count" -gt 0 ]; then
    pass "$count backup(s) in $ARCHIVE_DIR"
  else
    note "no backups yet in $ARCHIVE_DIR — run ./scripts/backup.sh"
  fi
else
  # Report the location even when it does not exist yet, so a mis-set
  # BACKUP_DIR is visible rather than silently producing no line at all.
  note "backups directory does not exist: $ARCHIVE_DIR — run ./scripts/backup.sh"
fi

size="$(du -sk "$BGC_PRIVATE" 2>/dev/null | awk '{print $1 * 1024}')"
if [ -n "$size" ]; then
  pass "data directory is $(human_bytes "$size")"
fi

avail="$(df -k "$BGC_PRIVATE" | tail -1 | awk '{print $4 * 1024}')"
if [ -n "$avail" ]; then
  if [ "$avail" -lt 2147483648 ]; then
    note "only $(human_bytes "$avail") free on this volume"
  else
    pass "$(human_bytes "$avail") free"
  fi
fi

# The php formula is not pinned, so a brew upgrade can move PHP under the
# services and they will fail to restart.
if brew list --pinned 2>/dev/null | grep -qx php; then
  pass "php formula is pinned"
else
  note "php formula is not pinned — a 'brew upgrade' can break the services"
  dim "to hold the current version:  brew pin php"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n'
if [ "$FAILS" -gt 0 ]; then
  printf '%s%d failure(s), %d warning(s)%s\n' "$C_RED" "$FAILS" "$WARNS" "$C_RESET"
  printf 'See docs/operations.md for the decision table.\n\n'
  exit 1
fi
printf '%sno failures (%d warning(s))%s\n\n' "$C_GREEN" "$WARNS" "$C_RESET"
exit 0
