#!/usr/bin/env bash
# =============================================================================
# upgrade.sh — update the container images safely
#
#   ./scripts/upgrade.sh              # backup, pull, recreate, verify
#   ./scripts/upgrade.sh --dry-run    # show what would change, change nothing
#   ./scripts/upgrade.sh --no-backup  # skip the automatic pre-upgrade backup
#
# Always backs up first unless told otherwise. Youlag requires FreshRSS >= 1.30.0;
# pinning an older tag silently breaks YouTube mode.
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

require_env_file
require_docker

# -----------------------------------------------------------------------------
# 1. Record the current state so a rollback is possible
# -----------------------------------------------------------------------------
info "current image state"

CURRENT=""
for svc in freshrss rss-bridge; do
  img="$(compose images "$svc" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | head -n 1 || true)"
  digest="$(compose images "$svc" --format '{{.ID}}' 2>/dev/null | head -n 1 || true)"
  if [ -n "$img" ]; then
    printf '  %-12s %s  (%s)\n' "$svc" "$img" "${digest:0:12}"
    CURRENT="${CURRENT}${svc}=${img}@${digest:0:12}
"
  else
    printf '  %-12s %s\n' "$svc" "(not present)"
  fi
done

printf '\n'
printf '%s  Rollback note%s: write these down. Docker does not track them for you.\n' \
  "$C_YELLOW" "$C_RESET"

# -----------------------------------------------------------------------------
# 2. Pull
# -----------------------------------------------------------------------------
info "pulling latest images"

if [ "$DRY_RUN" -eq 1 ]; then
  dim "dry run — would run: docker compose pull"
  compose config --images 2>/dev/null | sed 's/^/     /' || true
  printf '\n'
  info "dry run complete — nothing changed"
  exit 0
fi

compose pull

# -----------------------------------------------------------------------------
# 3. Backup first
# -----------------------------------------------------------------------------
if [ "$DO_BACKUP" -eq 1 ]; then
  if compose ps --status running --services 2>/dev/null | grep -q '^freshrss$'; then
    info "pre-upgrade backup"
    "$SELF_DIR/backup.sh" || die "backup failed — aborting the upgrade (nothing changed)"
  else
    warn "freshrss not running; skipping the pre-upgrade backup"
    warn "if this is a deliberate restore-in-progress, that is fine"
  fi
fi

# -----------------------------------------------------------------------------
# 4. Recreate
# -----------------------------------------------------------------------------
info "recreating containers"
compose up -d --remove-orphans
ok "recreated"

# -----------------------------------------------------------------------------
# 5. Verify
# -----------------------------------------------------------------------------
printf '\n'
dim "waiting for health (up to 120s)"
HEALTHY=0
for _ in $(seq 1 40); do
  if compose ps --format '{{.Service}} {{.Status}}' 2>/dev/null | grep -q '^freshrss .*(healthy)'; then
    HEALTHY=1
    break
  fi
  sleep 3
done

printf '\n'
if [ "$HEALTHY" -eq 1 ]; then
  ok "freshrss healthy after upgrade"
else
  warn "freshrss did not report healthy within 120s — inspect before trusting it"
  dim "docker compose logs --tail 50 freshrss"
fi

FR_VERSION="$(compose exec -T freshrss sh -c 'sed -n "s/.*FRESHRSS_VERSION.\{0,4\}\([0-9][^;\x27]*\).*/\1/p" /var/www/FreshRSS/constants.php 2>/dev/null | head -n 1' 2>/dev/null || true)"

printf '\n'
printf '  %snew image state%s\n' "$C_BLUE" "$C_RESET"
for svc in freshrss rss-bridge; do
  img="$(compose images "$svc" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | head -n 1 || true)"
  digest="$(compose images "$svc" --format '{{.ID}}' 2>/dev/null | head -n 1 || true)"
  printf '  %-12s %s  (%s)\n' "$svc" "${img:-(not present)}" "${digest:0:12}"
done
[ -n "$FR_VERSION" ] && printf '  %-12s %s\n' "freshRSS" "$FR_VERSION"
printf '\n'

info "running healthcheck"
"$SELF_DIR/healthcheck.sh" || warn "healthcheck reported problems — see docs/operations.md §4"

printf '\n'
dim "If something broke, roll back by pinning the previous tag in docker-compose.yml"
dim "and running: docker compose up -d --remove-orphans"
printf '\n'
