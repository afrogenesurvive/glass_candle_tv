#!/usr/bin/env bash
# =============================================================================
# backup.sh — snapshot the feed database
#
#   ./scripts/backup.sh                 # backup now
#   ./scripts/backup.sh --list          # show existing backups
#   ./scripts/backup.sh --include-env   # also copy .env (see the warning below)
#
# The feed database is the only thing here you cannot regenerate from a config
# file. Everything else can be rebuilt in ten minutes.
#
# NOTE: the freshrss container is stopped for a few seconds. SQLite is snapshotted
# while running would risk an inconsistent copy, and a clean shutdown checkpoints
# the write-ahead log. The outage is brief and the correctness is worth it.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

INCLUDE_ENV=0
LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list|-l)     LIST_ONLY=1 ;;
    --include-env) INCLUDE_ENV=1 ;;
    -h|--help)     sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
  shift
done

require_env_file

BACKUP_DIR="$(expand_path "$(get_env BACKUP_DIR "$HOME/Backups/black_glass_candle")")"
KEEP_DAYS="$(get_env BACKUP_KEEP_DAYS 30)"
VOL="black_glass_candle_freshrss_data"

if [ "$LIST_ONLY" -eq 1 ]; then
  [ -d "$BACKUP_DIR" ] || { info "no backups yet ($BACKUP_DIR does not exist)"; exit 0; }
  info "backups in $BACKUP_DIR"
  found=0
  for f in "$BACKUP_DIR"/freshrss-data-*.tar.gz; do
    [ -e "$f" ] || continue
    found=1
    printf '  %s  %s  %s\n' \
      "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')" \
      "$(printf '%8s' "$(human_bytes "$(wc -c < "$f" | tr -d ' ')")")" \
      "$(basename "$f")"
  done
  [ "$found" -eq 1 ] || info "no archives found"
  exit 0
fi

require_docker

TS="$(timestamp)"
mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"   # absolute, required for -v on macOS

ARCHIVE="$BACKUP_DIR/freshrss-data-${TS}.tar.gz"
MANIFEST="$BACKUP_DIR/MANIFEST-${TS}.txt"

WAS_RUNNING=0
STOPPED_BY_US=0

cleanup() {
  # Always bring the stack back, even if tar fails mid-way.
  if [ "$STOPPED_BY_US" -eq 1 ]; then
    info "restarting freshrss"
    compose start freshrss >/dev/null 2>&1 || warn "could not restart freshrss — run: docker compose up -d"
  fi
}
trap cleanup EXIT INT TERM

info "backing up to $BACKUP_DIR"

# -----------------------------------------------------------------------------
# 1. Quiesce
# -----------------------------------------------------------------------------
if compose ps --status running --services 2>/dev/null | grep -q '^freshrss$'; then
  WAS_RUNNING=1
  info "stopping freshrss for a consistent SQLite snapshot"
  compose stop freshrss >/dev/null
  STOPPED_BY_US=1
  ok "stopped"
else
  warn "freshrss was not running — backing up whatever is on disk"
fi

# -----------------------------------------------------------------------------
# 2. Snapshot the volume
# -----------------------------------------------------------------------------
info "archiving volume $VOL"

if ! docker volume inspect "$VOL" >/dev/null 2>&1; then
  die "volume $VOL does not exist. Has the stack ever been started? (docker compose up -d)"
fi

docker run --rm \
  -v "${VOL}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine:3 \
  tar czf "/backup/$(basename "$ARCHIVE")" -C /data . 2>/dev/null \
  || die "archive failed"

chmod 600 "$ARCHIVE"
ok "$(basename "$ARCHIVE")  ($(human_bytes "$(wc -c < "$ARCHIVE" | tr -d ' ')"))"

# -----------------------------------------------------------------------------
# 3. Extract a standalone SQLite file
# -----------------------------------------------------------------------------
# The tarball is the authoritative restore artefact, but a loose .sqlite is much
# easier to inspect and to restore selectively.
info "extracting standalone SQLite database"

SQLITE_PATH="$(tar tzf "$ARCHIVE" | grep -E 'db\.sqlite$' | head -n 1 || true)"
if [ -n "$SQLITE_PATH" ]; then
  SQLITE_OUT="$BACKUP_DIR/freshrss-${TS}.sqlite3"
  tar xzf "$ARCHIVE" -C "$BACKUP_DIR" "$SQLITE_PATH" 2>/dev/null || true
  if [ -f "$BACKUP_DIR/$SQLITE_PATH" ]; then
    mv "$BACKUP_DIR/$SQLITE_PATH" "$SQLITE_OUT"
    chmod 600 "$SQLITE_OUT"
    ok "freshrss-${TS}.sqlite3  ($(human_bytes "$(wc -c < "$SQLITE_OUT" | tr -d ' ')"))"
  else
    warn "could not extract $SQLITE_PATH"
  fi
  # Clean up the directory skeleton tar created.
  rmdir -p "$(dirname "$BACKUP_DIR/$SQLITE_PATH")" 2>/dev/null || true
else
  warn "no db.sqlite found in the archive — the user may never have logged in"
fi

# -----------------------------------------------------------------------------
# 4. Retention
# -----------------------------------------------------------------------------
info "pruning archives older than ${KEEP_DAYS} days"
pruned=0
for f in "$BACKUP_DIR"/freshrss-data-*.tar.gz "$BACKUP_DIR"/freshrss-*.sqlite3 "$BACKUP_DIR"/MANIFEST-*.txt; do
  [ -e "$f" ] || continue
  if find "$f" -mtime "+${KEEP_DAYS}" -print | grep -q .; then
    rm -f "$f"
    pruned=$((pruned + 1))
  fi
done
if [ "$pruned" -gt 0 ]; then
  ok "removed $pruned old file(s)"
else
  dim "nothing to prune"
fi

# -----------------------------------------------------------------------------
# 5. Manifest
# -----------------------------------------------------------------------------
FR_VERSION="$(docker run --rm -v "${VOL}:/data:ro" alpine:3 sh -c \
  'grep -oE "FRESHRSS_VERSION[^;]*" /data/config.php 2>/dev/null | head -n 1' 2>/dev/null || true)"
FEED_COUNT=""
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$BACKUP_DIR/freshrss-${TS}.sqlite3" ]; then
  FEED_COUNT="$(sqlite3 "$BACKUP_DIR/freshrss-${TS}.sqlite3" \
    "select count(*) from feed;" 2>/dev/null || true)"
fi

{
  printf 'black_glass_candle backup\n'
  printf 'created      %s\n' "$(date)"
  printf 'host         %s\n' "$(hostname)"
  printf 'archive      %s\n' "$(basename "$ARCHIVE")"
  printf 'sha256       %s\n' "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  printf 'size         %s\n' "$(human_bytes "$(wc -c < "$ARCHIVE" | tr -d ' ')")"
  printf 'feeds        %s\n' "${FEED_COUNT:-unknown}"
  printf 'freshRSS     %s\n' "${FR_VERSION:-unknown}"
  printf 'retention    %s days\n' "$KEEP_DAYS"
  printf '\nrestore with: ./scripts/restore.sh %s\n' "$ARCHIVE"
} > "$MANIFEST"
chmod 600 "$MANIFEST"
ok "MANIFEST-${TS}.txt"

# -----------------------------------------------------------------------------
# 6. Optional: .env
# -----------------------------------------------------------------------------
if [ "$INCLUDE_ENV" -eq 1 ]; then
  if command -v age >/dev/null 2>&1 && [ -f "$HOME/.age/key.txt" ]; then
    age -R "$HOME/.age/key.txt" -o "$BACKUP_DIR/env-${TS}.age" "$ENV_FILE"
    chmod 600 "$BACKUP_DIR/env-${TS}.age"
    ok "env-${TS}.age (encrypted)"
  else
    warn "skipping .env: 'age' or ~/.age/key.txt not available"
    warn "your .env belongs in your password manager, not in a backup directory"
  fi
fi

printf '\n'
ok "backup complete"
printf '\n'
dim "The OPML export is the portable artefact — it restores into any reader."
dim "Get it from the web UI: Subscription management -> Export (OPML)."
dim "Do that once and keep it alongside these archives."
printf '\n'

if [ "$WAS_RUNNING" -eq 1 ]; then
  dim "freshrss was restarted by this script."
fi
