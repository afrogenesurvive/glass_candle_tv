#!/usr/bin/env bash
# =============================================================================
# upgrade.sh — update FreshRSS and RSS-Bridge
#
#   ./scripts/upgrade.sh              # backup, pull, restart, verify
#   ./scripts/upgrade.sh --dry-run    # show what would change
#   ./scripts/upgrade.sh --no-backup  # skip the automatic pre-upgrade backup
#
# Natively, upgrading means `git pull` in the two clones rather than pulling
# container images. Your data is in a different directory from the code, so it is
# untouched by an upgrade — that separation is the main reason this layout
# survived the move away from Docker.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

DRY_RUN=0
DO_BACKUP=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=1 ;;
    --no-backup)  DO_BACKUP=0 ;;
    -h|--help)    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
  shift
done

require_private_dir
require_php

# -----------------------------------------------------------------------------
# Report what is currently checked out
# -----------------------------------------------------------------------------
info "current versions"

for pair in "FreshRSS:$FRESHRSS_DIR" "RSS-Bridge:$RSSBRIDGE_DIR"; do
  name="${pair%%:*}"; dir="${pair#*:}"
  if [ -d "$dir/.git" ]; then
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    commit="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '?')"
    subject="$(git -C "$dir" log -1 --format=%s 2>/dev/null | cut -c1-60 || echo '')"
    printf '  %-11s %s @ %s  %s\n' "$name" "$branch" "$commit" "$subject"
  else
    printf '  %-11s %s(not cloned)%s\n' "$name" "$C_DIM" "$C_RESET"
  fi
done

# FreshRSS reports its own version; useful because a failed pull can leave the
# code at a version that does not match what the UI advertises.
if [ -f "$FRESHRSS_DIR/constants.php" ]; then
  ver="$(sed -n 's/.*FRESHRSS_VERSION.\{0,4\}\([0-9][^;'"'"']*\).*/\1/p' "$FRESHRSS_DIR/constants.php" 2>/dev/null | head -1 || true)"
  [ -n "$ver" ] && printf '  %-11s %s\n' "app version" "$ver"
fi

printf '\n'
printf '%s  Rollback note%s: note the commit hashes above. Docker used to record\n' "$C_YELLOW" "$C_RESET"
printf '  image digests for you; git has nothing equivalent unless you write it down.\n'

# -----------------------------------------------------------------------------
# Fetch and preview
# -----------------------------------------------------------------------------
info "fetching"

for dir in "$FRESHRSS_DIR" "$RSSBRIDGE_DIR"; do
  [ -d "$dir/.git" ] || continue
  git -C "$dir" fetch --quiet --depth 1 origin 2>/dev/null || warn "$(basename "$dir"): fetch failed"
done
ok "fetched"

# A shallow clone is used at install time, so `git log` cannot show a full diff.
# Report the incoming commit rather than pretending to summarise it.
for pair in "FreshRSS:$FRESHRSS_DIR" "RSS-Bridge:$RSSBRIDGE_DIR"; do
  name="${pair%%:*}"; dir="${pair#*:}"
  [ -d "$dir/.git" ] || continue
  head_local="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo '')"
  head_remote="$(git -C "$dir" rev-parse '@{u}' 2>/dev/null || echo '')"
  if [ -n "$head_local" ] && [ "$head_local" != "$head_remote" ]; then
    printf '  %-11s %sbehind%s  %s -> %s\n' "$name" "$C_YELLOW" "$C_RESET" \
      "${head_local:0:8}" "${head_remote:0:8}"
  else
    printf '  %-11s %sup to date%s\n' "$name" "$C_GREEN" "$C_RESET"
  fi
done

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\n'
  info "dry run complete — nothing changed"
  exit 0
fi

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------
if [ "$DO_BACKUP" -eq 1 ]; then
  if [ -d "$FRESHRSS_DIR/data/users" ]; then
    info "pre-upgrade backup"
    "$SELF_DIR/backup.sh" || die "backup failed — aborting the upgrade (nothing changed)"
  else
    warn "no FreshRSS user data yet; skipping the backup"
  fi
fi

# -----------------------------------------------------------------------------
# Pull
# -----------------------------------------------------------------------------
info "updating"

for dir in "$FRESHRSS_DIR" "$RSSBRIDGE_DIR"; do
  [ -d "$dir/.git" ] || continue
  # --ff-only: a merge commit here would mean the clone has local edits, which
  # this script never makes. Failing loudly is better than creating a conflict.
  if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
    ok "$(basename "$dir") updated to $(git -C "$dir" rev-parse --short HEAD)"
  else
    warn "$(basename "$dir") could not fast-forward"
    dim "local changes? inspect:  git -C $dir status"
  fi
done

# FreshRSS may ship new extension hooks or schema migrations; restarting is what
# applies them.
info "restarting services"
"$SELF_DIR/services.sh" restart >/dev/null 2>&1 || true
ok "restarted"

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------
printf '\n'
dim "waiting for FreshRSS (up to 60s)"
healthy=0
for _ in $(seq 1 30); do
  code="$(http_code "http://127.0.0.1:$(freshrss_port)/" 5)"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then healthy=1; break; fi
  sleep 2
done

printf '\n'
if [ "$healthy" -eq 1 ]; then
  ok "FreshRSS answering after upgrade"
else
  warn "FreshRSS did not answer within 60s"
  dim "logs: private/logs/freshrss-stderr.log"
fi

info "running healthcheck"
"$SELF_DIR/healthcheck.sh" || warn "healthcheck reported problems — see docs/operations.md"

printf '\n'
dim "FreshRSS may require a schema migration on first request after an upgrade;"
dim "if the UI reports one, follow it in the browser."
printf '\n'
