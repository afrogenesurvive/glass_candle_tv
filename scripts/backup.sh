#!/usr/bin/env bash
# =============================================================================
# backup.sh — snapshot the feed database and configuration
#
#   ./scripts/backup.sh              # backup now
#   ./scripts/backup.sh --list       # show existing backups
#
# Natively this is a plain tar of a folder, which is the whole point of not using
# Docker: there is no VM disk image to go through, no `docker run` to extract a
# volume, and you can open the result in Finder.
#
# The freshrss service is stopped for the duration. Its SQLite database runs in
# write-ahead-log mode, and copying the files while it is being written risks a
# torn snapshot. A clean shutdown checkpoints the WAL first.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

KEEP_DAYS_DEFAULT=30

LIST_ONLY=0
case "${1-}" in
  --list|-l) LIST_ONLY=1 ;;
  -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) die "unknown argument: $1" ;;
esac

require_private_dir

if [ "$LIST_ONLY" -eq 1 ]; then
  [ -d "$BACKUPS_DIR" ] || { info "no backups yet"; exit 0; }
  info "backups in private/backups"
  found=0
  for f in "$BACKUPS_DIR"/*.tar.gz; do
    [ -e "$f" ] || continue
    found=1
    printf '  %s  %9s  %s\n' \
      "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')" \
      "$(human_bytes "$(wc -c < "$f" | tr -d ' ')")" \
      "$(basename "$f")"
  done
  [ "$found" -eq 1 ] || info "no archives found"
  exit 0
fi

require_env_file

KEEP_DAYS="$(get_env BACKUP_KEEP_DAYS "$KEEP_DAYS_DEFAULT")"
TS="$(timestamp)"
ARCHIVE="$BACKUPS_DIR/freshrss-data-$TS.tar.gz"
MANIFEST="$BACKUPS_DIR/MANIFEST-$TS.txt"

mkdir -p "$BACKUPS_DIR"

# -----------------------------------------------------------------------------
# What goes in
# -----------------------------------------------------------------------------
# data/ holds subscriptions, categories, articles and read state — the only
# thing here that cannot be regenerated from a config file.
# private/env holds the passwords and tokens the services need to start.
TARGETS=""
[ -d "$FRESHRSS_DIR/data" ] && TARGETS="$TARGETS FreshRSS/data"
[ -d "$RSSBRIDGE_DIR/config" ] && TARGETS="$TARGETS rss-bridge/config"
[ -f "$ENV_FILE" ] && TARGETS="$TARGETS env"

if [ -z "$TARGETS" ]; then
  die "nothing to back up — is FreshRSS installed? ($FRESHRSS_DIR)"
fi

info "backing up to private/backups"
dim "including:$TARGETS"

# -----------------------------------------------------------------------------
# Quiesce
# -----------------------------------------------------------------------------
STOPPED=0
cleanup() {
  if [ "$STOPPED" -eq 1 ]; then
    info "restarting freshrss"
    "$SELF_DIR/services.sh" start freshrss >/dev/null 2>&1 \
      || warn "could not restart freshrss — run: ./scripts/services.sh start"
  fi
}
trap cleanup EXIT INT TERM

if [ "$(agent_state freshrss)" = "running" ]; then
  info "stopping freshrss for a consistent SQLite snapshot"
  "$SELF_DIR/services.sh" stop freshrss >/dev/null
  STOPPED=1
  ok "stopped"
else
  warn "freshrss was not running — backing up whatever is on disk"
fi

# -----------------------------------------------------------------------------
# Archive
# -----------------------------------------------------------------------------
# Run from private/ so the paths inside the archive are relative and portable:
# they do not embed the absolute path of your home directory.
info "archiving"
tar czf "$ARCHIVE" -C "$BGC_PRIVATE" \
  $(for t in $TARGETS; do printf '%s ' "$t"; done) 2>/dev/null \
  || die "tar failed"

chmod 600 "$ARCHIVE"
ok "$(basename "$ARCHIVE")  ($(human_bytes "$(wc -c < "$ARCHIVE" | tr -d ' ')"))"

# A standalone database file is worth having alongside the archive, for the
# common case of wanting to inspect or restore just one thing.
DB_PATH="$(find "$FRESHRSS_DIR/data" -name 'db.sqlite' 2>/dev/null | head -n 1 || true)"
if [ -n "$DB_PATH" ]; then
  cp "$DB_PATH" "$BACKUPS_DIR/freshrss-$TS.sqlite3" 2>/dev/null \
    && chmod 600 "$BACKUPS_DIR/freshrss-$TS.sqlite3" \
    && ok "freshrss-$TS.sqlite3  ($(human_bytes "$(wc -c < "$BACKUPS_DIR/freshrss-$TS.sqlite3" | tr -d ' ')"))"
fi

# -----------------------------------------------------------------------------
# Retention
# -----------------------------------------------------------------------------
info "pruning archives older than ${KEEP_DAYS} days"
pruned=0
for f in "$BACKUPS_DIR"/*.tar.gz "$BACKUPS_DIR"/*.sqlite3 "$BACKUPS_DIR"/MANIFEST-*.txt; do
  [ -e "$f" ] || continue
  if find "$f" -mtime "+${KEEP_DAYS}" -print | grep -q .; then
    rm -f "$f"
    pruned=$((pruned + 1))
  fi
done
[ "$pruned" -gt 0 ] && ok "removed $pruned old file(s)" || dim "nothing to prune"

# -----------------------------------------------------------------------------
# Manifest
# -----------------------------------------------------------------------------
FEED_COUNT=""
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$BACKUPS_DIR/freshrss-$TS.sqlite3" ]; then
  FEED_COUNT="$(sqlite3 "$BACKUPS_DIR/freshrss-$TS.sqlite3" 'select count(*) from feed;' 2>/dev/null || true)"
fi

{
  printf 'glass_candle_tv backup\n'
  printf 'created    %s\n' "$(date)"
  printf 'host       %s\n' "$(hostname)"
  printf 'archive    %s\n' "$(basename "$ARCHIVE")"
  printf 'sha256     %s\n' "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  printf 'size       %s\n' "$(human_bytes "$(wc -c < "$ARCHIVE" | tr -d ' ')")"
  printf 'feeds      %s\n' "${FEED_COUNT:-unknown}"
  printf 'php        %s\n' "$PHP_VER"
  printf 'retention  %s days\n' "$KEEP_DAYS"
  printf '\nrestore with: ./scripts/restore.sh %s\n' "$ARCHIVE"
} > "$MANIFEST"
chmod 600 "$MANIFEST"
ok "MANIFEST-$TS.txt"

printf '\n'
ok "backup complete"
printf '\n'
dim "The OPML export is the portable artefact — it restores into any reader."
dim "Get one from the web UI: Subscription management -> Export (OPML)."
printf '\n'
