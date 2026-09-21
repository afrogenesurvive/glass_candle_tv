#!/usr/bin/env bash
# =============================================================================
# set-admin-credentials.sh — set the FreshRSS admin login, without an editor
#
#   ./scripts/set-admin-credentials.sh
#
# Prompts for the admin email and password (input hidden), stores them in
# private/env, and applies the password to the FreshRSS account — updating it if
# it already exists.
#
# Run this from a terminal you are sitting at, then re-run ./scripts/install.sh
# to create the account if it does not exist yet.
#
# Why this is a separate script and not a prompt inside install.sh: an installer
# must never block. Run non-interactively, a prompt hangs — and whatever text
# arrives next is read as the answer. That is not hypothetical: a shell command
# was once stored as an admin password that way.
#
# One caveat: FreshRSS's CLI accepts the password only as a command argument, so
# it is briefly visible to `ps` on this machine. There is no stdin alternative.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

case "${1-}" in
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) die "unknown argument: $1" ;;
esac

require_env_file

ADMIN_USERNAME="$(get_env ADMIN_USER admin)"
USER_DIR="$FRESHRSS_DIR/data/users/$ADMIN_USERNAME"

info "admin credentials"

CURRENT_EMAIL="$(get_env ADMIN_EMAIL)"
printf '  Admin email'
[ -n "$CURRENT_EMAIL" ] && printf ' [%s]' "$CURRENT_EMAIL"
printf ': '
read -r EMAIL_IN || true
[ -n "${EMAIL_IN-}" ] || EMAIL_IN="$CURRENT_EMAIL"
[ -n "$EMAIL_IN" ] || die "an email address is required"

printf '  Admin password (hidden, minimum 8 characters): '
read -r -s PW1 || true
printf '\n'
printf '  Confirm password: '
read -r -s PW2 || true
printf '\n'

[ -n "${PW1-}" ] || die "no password entered — nothing changed"
[ "$PW1" = "${PW2-}" ] || die "the two passwords do not match — nothing changed"
[ "${#PW1}" -ge 8 ] || die "the password must be at least 8 characters"

set_env_value ADMIN_EMAIL "$EMAIL_IN"
set_env_value ADMIN_PASSWORD "$PW1"
ok "saved ADMIN_EMAIL and ADMIN_PASSWORD to private/env"

# -----------------------------------------------------------------------------
# Apply it
# -----------------------------------------------------------------------------
if [ -f "$USER_DIR/config.php" ]; then
  info "updating the existing account"
  if php "$FRESHRSS_DIR/cli/update-user.php" \
        --user "$ADMIN_USERNAME" --password "$PW1" >/dev/null 2>&1; then
    ok "password updated for '$ADMIN_USERNAME'"
  else
    warn "could not update the account"
    dim "run it by hand to see why:"
    dim "  php \"$FRESHRSS_DIR/cli/update-user.php\" --user $ADMIN_USERNAME --password '<new>'"
  fi
else
  info "no account exists yet"
  dim "next:  ./scripts/install.sh    (creates it with these credentials)"
fi

unset PW1 PW2 EMAIL_IN

printf '\n'
dim "The FreshRSS API password is separate (ADMIN_API_PASSWORD); this script"
dim "does not change it. See docs/inputs_required.md section B2."
printf '\n'