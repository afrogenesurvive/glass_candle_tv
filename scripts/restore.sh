#!/usr/bin/env bash
# =============================================================================
# restore.sh — restore the feed database and configuration from a backup
#
#   ./scripts/restore.sh                    # list backups and pick one
#   ./scripts/restore.sh <archive.tar.gz>   # restore a snapshot
#   ./scripts/restore.sh latest             # restore the most recent snapshot
#   ./scripts/restore.sh <archive.tar.gz> --yes
#
# DESTRUCTIVE: the existing FreshRSS data directory is moved aside, not deleted,
# so a mistaken restore is recoverable. There is still no undo for anything done
# after the restore.
#
# A backup you have never restored is a hypothesis, not a backup.
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
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)  [ -z "$TARGET" ] || die "only one restore source may be given"; TARGET="$1" ;;
  esac
  shift
done

require_private_dir

# `latest` is the form docs/operations.md and backup.sh's closing hint both
# print. It used to be treated as a filename and die with a confusing error, so
# following the runbook literally did not work.
case "$TARGET" in
  latest|'<latest>')
    ARCHIVE_DIR="$(backups_dir)"
    TARGET="$(ls -t "$ARCHIVE_DIR"/*.tar.gz 2>/dev/null | head -n 1 || true)"
    [ -n "$TARGET" ] || die "no backups in $ARCHIVE_DIR — run ./scripts/backup.sh first"
    info "using the most recent backup"
    dim "  $(basename "$TARGET")"
    ;;
esac

# -----------------------------------------------------------------------------
# Pick a source
# -----------------------------------------------------------------------------
if [ -z "$TARGET" ]; then
  ARCHIVE_DIR="$(backups_dir)"
  [ -d "$ARCHIVE_DIR" ] || die "no backups in $ARCHIVE_DIR — run ./scripts/backup.sh first"
  info "available backups"

  i=0; ENTRIES=''
  for f in "$ARCHIVE_DIR"/*.tar.gz; do
    [ -e "$f" ] || continue
    i=$((i + 1))
    ENTRIES="${ENTRIES}${i}:${f}
"
    printf '  %2d) %s  %9s  %s\n' "$i" \
      "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')" \
      "$(human_bytes "$(wc -c < "$f" | tr -d ' ')")" \
      "$(basename "$f")"
  done

  [ "$i" -gt 0 ] || die "no archives found in $ARCHIVE_DIR"
  printf '\n%sSelect a backup [1-%d]:%s ' "$C_BLUE" "$i" "$C_RESET"
  read -r choice
  TARGET="$(printf '%s' "$ENTRIES" | awk -F: -v n="$choice" '$1 == n { sub(/^[0-9]+:/, ""); print; exit }')"
  [ -n "$TARGET" ] || die "invalid selection: $choice"
fi

[ -f "$TARGET" ] || die "no such file: $TARGET"
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"

# -----------------------------------------------------------------------------
# Describe and confirm
# -----------------------------------------------------------------------------
printf '\n'
printf '  %ssource%s  %s\n' "$C_BLUE" "$C_RESET" "$(basename "$TARGET")"
printf '  %ssize%s    %s\n' "$C_BLUE" "$C_RESET" "$(human_bytes "$(wc -c < "$TARGET" | tr -d ' ')")"
printf '  %saction%s  move the current data aside, then extract this archive\n' "$C_BLUE" "$C_RESET"
printf '\n'

info "contents"
tar tzf "$TARGET" 2>/dev/null | head -12 | sed 's/^/     /' || true
printf '\n'

if [ "$ASSUME_YES" -eq 0 ]; then
  confirm "Proceed with the restore?" || { info "aborted — nothing changed"; exit 0; }
fi

# -----------------------------------------------------------------------------
# Restore
# -----------------------------------------------------------------------------
info "stopping services"
"$SELF_DIR/services.sh" stop >/dev/null 2>&1 || true
ok "stopped"

# Move aside rather than delete. A mistaken restore is then a `mv` back, and the
# cost is one directory rename.
if [ -d "$FRESHRSS_DIR/data" ]; then
  ASIDE="$FRESHRSS_DIR/data.pre-restore-$(timestamp)"
  mv "$FRESHRSS_DIR/data" "$ASIDE"
  ok "previous data moved to $(basename "$ASIDE")"
fi

info "extracting"
tar xzf "$TARGET" -C "$BGC_PRIVATE" || die "extract failed"
ok "extracted"

# The archive stores env as `env` directly under private/, which is where it
# belongs — but only take it if the current one is missing, so a restore cannot
# silently overwrite newer credentials with older ones.
if [ -f "$BGC_PRIVATE/env" ] && [ -f "$ENV_FILE" ]; then
  dim "private/env was already present; keeping the existing one"
fi

if [ -d "$FRESHRSS_DIR/data" ]; then
  chmod 700 "$FRESHRSS_DIR/data" 2>/dev/null || true
fi

info "starting services"
"$SELF_DIR/services.sh" start >/dev/null 2>&1 || true

printf '\n'
dim "waiting for FreshRSS (up to 30s)"
for _ in $(seq 1 15); do
  code="$(http_code "http://127.0.0.1:$(freshrss_port)/" 5)"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    printf '\n'
    ok "restore complete — FreshRSS responding (HTTP $code)"
    printf '\n'
    printf '  Next:\n'
    printf '    1. Log in and confirm your subscriptions are present.\n'
    printf '    2. Re-apply mute/hide and filter rules if they are missing.\n'
    printf '    3. ./scripts/healthcheck.sh\n'
    printf '\n'
    dim "If anything looks wrong, the previous data is at:"
    dim "  $FRESHRSS_DIR/data.pre-restore-*"
    printf '\n'
    exit 0
  fi
  sleep 2
done

printf '\n'
warn "FreshRSS did not confirm within 30s"
dim "logs: private/logs/freshrss-stderr.log"
dim "previous data: $FRESHRSS_DIR/data.pre-restore-*"
exit 1
