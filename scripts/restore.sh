#!/usr/bin/env bash
# =============================================================================
# restore.sh — restore the feed database from a backup
#
#   ./scripts/restore.sh                    # list backups and pick one
#   ./scripts/restore.sh <archive.tar.gz>   # restore a full data snapshot
#   ./scripts/restore.sh <db.sqlite3>       # restore only the database file
#   ./scripts/restore.sh <path> --yes       # skip the confirmation prompt
#
# DESTRUCTIVE: the existing feed database is deleted first. There is no undo.
#
# A backup you have never restored is a hypothesis, not a backup. Run this
# deliberately at least once, against a scratch instance, before you need it.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

ASSUME_YES=0
TARGET=''
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)  [ -z "$TARGET" ] || die "only one restore source may be given"
        TARGET="$1" ;;
  esac
  shift
done

require_env_file
require_docker

BACKUP_DIR="$(expand_path "$(get_env BACKUP_DIR "$HOME/Backups/black_glass_candle")")"
VOL="black_glass_candle_freshrss_data"

# -----------------------------------------------------------------------------
# Pick a source
# -----------------------------------------------------------------------------
if [ -z "$TARGET" ]; then
  [ -d "$BACKUP_DIR" ] || die "no backup directory at $BACKUP_DIR"
  info "available backups in $BACKUP_DIR"

  i=0
  ENTRIES=''
  for f in "$BACKUP_DIR"/freshrss-data-*.tar.gz "$BACKUP_DIR"/freshrss-*.sqlite3; do
    [ -e "$f" ] || continue
    i=$((i + 1))
    ENTRIES="${ENTRIES}${i}:${f}
"
    printf '  %2d) %s  %s  %s\n' "$i" \
      "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')" \
      "$(printf '%8s' "$(human_bytes "$(wc -c < "$f" | tr -d ' ')")")" \
      "$(basename "$f")"
  done

  [ "$i" -gt 0 ] || die "no backups found in $BACKUP_DIR"
  printf '\n'
  printf 'Select a backup [1-%d]: ' "$i"
  read -r choice
  TARGET="$(printf '%s' "$ENTRIES" | awk -F: -v n="$choice" '$1 == n { sub(/^[0-9]+:/, ""); print; exit }')"
  [ -n "$TARGET" ] || die "invalid selection: $choice"
fi

[ -f "$TARGET" ] || die "no such file: $TARGET"
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"

# -----------------------------------------------------------------------------
# Describe the plan, then confirm
# -----------------------------------------------------------------------------
case "$TARGET" in
  *.tar.gz) MODE="full" ;;
  *.sqlite3|*.sqlite|*.db) MODE="db-only" ;;
  *) die "unrecognised file type: $(basename "$TARGET").
       Expected .tar.gz (full snapshot) or .sqlite3 (database only)." ;;
esac

printf '\n'
printf '  %ssource%s   %s\n' "$C_BLUE" "$C_RESET" "$(basename "$TARGET")"
printf '  %smode%s     %s\n' "$C_BLUE" "$C_RESET" \
  "$([ "$MODE" = full ] && echo 'full data snapshot (config + database)' || echo 'database file only (config kept)')"
printf '  %starget%s   volume %s\n' "$C_BLUE" "$C_RESET" "$VOL"
printf '  %sresult%s   the current feed database is DELETED and replaced\n' "$C_RED" "$C_RESET"
printf '\n'

if [ "$ASSUME_YES" -eq 0 ]; then
  if ! confirm "Proceed with the restore?"; then
    info "aborted — nothing changed"
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# Stop everything
# -----------------------------------------------------------------------------
info "stopping containers"
compose down >/dev/null 2>&1 || true
ok "stopped"

docker volume inspect "$VOL" >/dev/null 2>&1 || {
  warn "volume $VOL does not exist; creating it empty so it can be populated"
  docker volume create "$VOL" >/dev/null
}

# -----------------------------------------------------------------------------
# Restore
# -----------------------------------------------------------------------------
if [ "$MODE" = "full" ]; then
  info "restoring full snapshot"
  docker run --rm \
    -v "${VOL}:/data" \
    -v "$(dirname "$TARGET"):/src:ro" \
    alpine:3 \
    sh -c 'set -e
            rm -rf /data/* /data/.[!.]* 2>/dev/null || true
            tar xzf "/src/$(basename "$TARGET")" -C /data' \
    || die "restore failed"
  ok "snapshot restored"
else
  info "restoring database file only"

  # Find where the database lives inside the existing volume, so a db-only
  # restore lands in the right user directory without guessing the username.
  DB_DIR="$(docker run --rm -v "${VOL}:/data:ro" alpine:3 \
    sh -c 'find /data -name db.sqlite -printf "%h\n" 2>/dev/null | head -n 1' 2>/dev/null || true)"

  if [ -z "$DB_DIR" ]; then
    DB_USER_DIR="$(get_env MENUBAR_API_USER admin)"
    DB_DIR="/data/users/./${DB_USER_DIR}"
    warn "no existing db.sqlite found; will restore to ${DB_DIR#/data}"
  else
    ok "target directory: ${DB_DIR#/data}"
  fi

  docker run --rm \
    -v "${VOL}:/data" \
    -v "$(dirname "$TARGET"):/src:ro" \
    alpine:3 \
    sh -c "set -e
           mkdir -p '$DB_DIR'
           rm -f '$DB_DIR'/db.sqlite-wal '$DB_DIR'/db.sqlite-shm
           cp '/src/$(basename "$TARGET")' '$DB_DIR/db.sqlite'
           chmod 600 '$DB_DIR/db.sqlite'" \
    || die "restore failed"
  ok "database restored"
fi

# -----------------------------------------------------------------------------
# Restart and verify
# -----------------------------------------------------------------------------
info "starting containers"
compose up -d >/dev/null

printf '\n'
dim "waiting for freshrss to become healthy (up to 90s)"
for _ in $(seq 1 30); do
  if compose ps --format '{{.Service}} {{.Status}}' 2>/dev/null | grep -q '^freshrss .*(healthy)'; then
    ok "freshrss healthy"
    break
  fi
  sleep 3
done

FR_PORT="$(get_env FRESHRSS_PORT 8080)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${FR_PORT}/" 2>/dev/null || printf '000')"

printf '\n'
if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
  ok "restore complete — FreshRSS responding on :${FR_PORT}"
  printf '\n'
  printf '  Next:\n'
  printf '    1. Log in and confirm your subscriptions are present.\n'
  printf '    2. Re-apply mute/hide and filter rules if this was a db-only restore.\n'
  printf '    3. Run: ./scripts/healthcheck.sh\n'
else
  warn "FreshRSS returned HTTP $CODE — check the logs:"
  dim "docker compose logs -f --timestamps freshrss"
  exit 1
fi
printf '\n'
