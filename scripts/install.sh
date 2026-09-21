#!/usr/bin/env bash
# =============================================================================
# install.sh — set up glass_candle_tv natively (no Docker)
#
#   ./scripts/install.sh              # full install, idempotent
#   ./scripts/install.sh --no-services  # set up but do not load launchd agents
#   ./scripts/install.sh --dry-run      # report what would happen
#
# What it does, in order:
#   1. checks Homebrew + PHP (the built-in server is all that is needed)
#   2. creates the data directory — OUTSIDE the repo, which is where all
#      personal state lives and why the repo stays safe to publish
#   3. creates the config file (env) from .env.example if it does not exist
#   4. clones FreshRSS and RSS-Bridge into the data directory
#   5. generates the RSS-Bridge request router and config from env
#   6. installs user-level launchd agents (freshrss, rssbridge, refresh)
#   7. creates the admin account via FreshRSS's CLI, if credentials are set
#
# Deliberately non-interactive: it never prompts, so it is safe to run from a
# script. Set the admin login with ./scripts/set-admin-credentials.sh.
#
# Nothing is installed system-wide, and no step needs sudo.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

DO_SERVICES=1
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-services) DO_SERVICES=0 ;;
    --dry-run|-n)  DRY_RUN=1 ;;
    -h|--help)     sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
  shift
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s  would run:%s %s\n' "$C_DIM" "$C_RESET" "$*"
    return 0
  fi
  "$@"
}

FRESHRSS_REPO="https://github.com/FreshRSS/FreshRSS.git"
FRESHRSS_BRANCH="latest"
RSSBRIDGE_REPO="https://github.com/RSS-Bridge/rss-bridge.git"

printf '\n%sglass_candle_tv — native installer%s\n\n' "$C_BLUE" "$C_RESET"

# =============================================================================
# 1. Prerequisites
# =============================================================================
info "prerequisites"

require_brew
ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"

require_php
ok "PHP $PHP_VER at $PHP_BIN"

# No web server to install. The stack runs PHP's built-in server, one process per
# app, supervised by launchd. That keeps the dependency list at exactly one thing
# (PHP, already present) and avoids touching Homebrew's tap-trust configuration.
if ! "$PHP_BIN" -r 'exit(PHP_SAPI === "cli" ? 0 : 1);' 2>/dev/null; then
  die "this PHP build has no CLI SAPI, which the built-in server requires"
fi
ok "PHP CLI server available ($(php_cli_workers) workers)"

if ! command -v git >/dev/null 2>&1; then
  die "git not found.  Install it:  brew install git"
fi
ok "git present"

# The PHP version is not pinned, so a future `brew upgrade` can move it. Say so
# once, here, where the user is already thinking about the toolchain.
if ! brew list --pinned 2>/dev/null | grep -qx php; then
  warn "the php formula is not pinned — a future 'brew upgrade' can move PHP and break the stack"
  dim "if you want to hold the current version:  brew pin php"
fi

# =============================================================================
# 2. Directory skeleton
# =============================================================================
info "creating the data directory"

run mkdir -p "$APPS_DIR" "$ETC_DIR" "$RUN_DIR" "$LOGS_DIR" "$BACKUPS_DIR"
[ "$DRY_RUN" -eq 0 ] && ok "created {apps,etc,run,logs,backups}"

# Outside the repo deliberately, and not as a matter of taste: the refresh agent
# is started by launchd, and a launchd-spawned /bin/bash cannot read ~/Documents,
# ~/Desktop or ~/Downloads at all (macOS TCC — the measurement is in
# lib-common.sh). Anything a scheduled job must read therefore has to live
# somewhere else. The repo may still live anywhere you like: git, the editor and
# these scripts all run from a terminal, which does have access.
printf '\n'
dim "data directory: $BGC_PRIVATE"
printf '\n'

# An older in-repo private/ is reported rather than migrated: which copy is
# authoritative is a decision for whoever has both in front of them.
if [ -d "$BGC_ROOT/private" ]; then
  warn "an older in-repo private/ still exists: $BGC_ROOT/private"
  dim "the live data is now $BGC_PRIVATE"
  dim "after checking its contents:  rm -rf \"$BGC_ROOT/private\""
fi

# =============================================================================
# 3. Config file
# =============================================================================
if [ ! -f "$ENV_FILE" ]; then
  info "creating the config file from the template"
  run cp "$ENV_EXAMPLE" "$ENV_FILE"
  [ "$DRY_RUN" -eq 0 ] && ok "created $ENV_FILE"
  printf '\n'
  warn "the config file is EMPTY of secrets. Fill it in before continuing:"
  dim "  \$EDITOR \"$ENV_FILE\""
  dim "  see docs/inputs_required.md for every value"
  printf '\n'
else
  ok "config file exists ($ENV_FILE)"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  # These two are consumed by config generation and the launched services, so
  # they are genuinely required for a working install.
  require_vars ADMIN_API_PASSWORD RSSBRIDGE_TOKEN
  ok "API secrets present"

  # ADMIN_EMAIL and ADMIN_PASSWORD are only inputs to creating the admin
  # account. Their absence is not fatal: the stack installs and runs perfectly
  # well without an account, which can be created later from the web UI, or by
  # setting these and re-running this script.
  #
  # Deliberately NOT prompted for here. An installer must never block on input:
  # run non-interactively it hangs, and whatever text arrives next is consumed
  # as the answer — which is how a shell command can end up stored as a
  # password. Set these with scripts/set-admin-credentials.sh from a real
  # terminal instead.
  if [ -z "$(get_env ADMIN_EMAIL)" ] || [ -z "$(get_env ADMIN_PASSWORD)" ]; then
    warn "ADMIN_EMAIL and/or ADMIN_PASSWORD are empty"
    dim "the admin account will NOT be created — see the end of this output"
    dim "set them with:  ./scripts/set-admin-credentials.sh"
  fi
fi

# =============================================================================
# 4. Application clones
# =============================================================================
info "application code"

clone_if_missing() {
  local dir="$1" repo="$2" branch="${3-}" label="$4"
  if [ -d "$dir/.git" ]; then
    ok "$label already cloned"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    dim "would clone $repo into ${dir#"$BGC_ROOT"/}"
    return 0
  fi
  mkdir -p "$(dirname "$dir")"
  if [ -n "$branch" ]; then
    git clone --depth 1 --branch "$branch" "$repo" "$dir" >/dev/null 2>&1 \
      || die "failed to clone $label from $repo (branch $branch)"
  else
    git clone --depth 1 "$repo" "$dir" >/dev/null 2>&1 \
      || die "failed to clone $label from $repo"
  fi
  ok "$label cloned"
}

clone_if_missing "$FRESHRSS_DIR" "$FRESHRSS_REPO" "$FRESHRSS_BRANCH" "FreshRSS"
clone_if_missing "$RSSBRIDGE_DIR" "$RSSBRIDGE_REPO" "" "RSS-Bridge"

# FreshRSS keeps everything personal in ./data — the database, subscriptions,
# categories, and per-user config. The docroot points at ./p, a sibling of
# data/, so this directory is not reachable over HTTP at all.
if [ -d "$FRESHRSS_DIR" ] && [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$FRESHRSS_DIR/data"
  chmod 700 "$FRESHRSS_DIR/data" 2>/dev/null || true
  ok "FreshRSS data directory ready (not web-exposed)"
fi

# =============================================================================
# 5. Generated configs
# =============================================================================
info "generating service config"
if [ "$DRY_RUN" -eq 1 ]; then
  dim "would run: ./scripts/gen-configs.sh"
else
  "$SELF_DIR/gen-configs.sh" >/dev/null || die "config generation failed"
  ok "RSS-Bridge router + bridge config generated"
  dim "FreshRSS needs no router: its docroot is the app's p/ folder, so the"
  dim "data folder is never inside the served tree."
fi

# =============================================================================
# 6. Sanity-check the docroots before loading anything
# =============================================================================
if [ "$DRY_RUN" -eq 0 ]; then
  info "checking docroots"
  [ -f "$FRESHRSS_DIR/p/index.php" ] \
    || die "missing $FRESHRSS_DIR/p/index.php — the FreshRSS clone looks incomplete"
  ok "FreshRSS docroot looks right (p/index.php)"

  if [ -d "$FRESHRSS_DIR/data" ]; then
    # The point of the whole layout: the personal data must NOT be under the
    # docroot. If it ever is, the web server is serving it.
    case "$FRESHRSS_DIR/data" in
      "$FRESHRSS_DIR/p"/*) die "data/ is inside the docroot. Refusing to continue." ;;
    esac
    ok "FreshRSS data/ is outside the docroot"
  fi
fi

# =============================================================================
# 7. launchd agents
# =============================================================================
if [ "$DO_SERVICES" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    info "installing launch agents"
    dim "would run: ./scripts/services.sh install"
  else
    "$SELF_DIR/services.sh" install || die "service installation failed"
  fi
else
  dim "skipping service installation (--no-services)"
fi

# =============================================================================
# 8. FreshRSS admin account
# =============================================================================
# FreshRSS ships a CLI installer, which is how the Docker image's FRESHRSS_INSTALL
# and FRESHRSS_USER variables worked. Using it here means no web wizard, and the
# account is created from the same values.
if [ "$DRY_RUN" -eq 0 ] && [ -d "$FRESHRSS_DIR" ] && [ "$DO_SERVICES" -eq 1 ]; then
  info "checking FreshRSS installation"

  FR_PORT="$(freshrss_port)"
  BASE_URL="$(get_env BASE_URL "http://127.0.0.1:$FR_PORT")"
  ADMIN_USER_VALUE="$(get_env ADMIN_USER admin)"

  # Give the services a moment to bind their ports.
  for _ in $(seq 1 10); do
    port_listening "$FR_PORT" && break
    sleep 1
  done

  if [ -f "$FRESHRSS_DIR/data/config.php" ]; then
    ok "FreshRSS is already installed"
  elif [ -z "$(get_env ADMIN_PASSWORD)" ]; then
    # Skip cleanly rather than running half an installer: do-install.php would
    # succeed while create-user.php failed, leaving a database with no account
    # and a confusing state to recover from.
    warn "skipping FreshRSS setup — ADMIN_PASSWORD is empty"
    dim "set ADMIN_PASSWORD in private/env and re-run ./scripts/install.sh"
    dim "or open http://127.0.0.1:$FR_PORT and use the web installer"
  else
    dim "running the FreshRSS CLI installer"
    if "$PHP_BIN" "$FRESHRSS_DIR/cli/do-install.php" \
         --default-user "$ADMIN_USER_VALUE" \
         --base-url "$BASE_URL" \
         --language "$(get_env FRESHRSS_LANGUAGE en)" \
         --db-type sqlite >/dev/null 2>&1; then
      ok "base installation done"
    else
      warn "CLI install did not complete — finish it in the browser instead"
    fi

    if "$PHP_BIN" "$FRESHRSS_DIR/cli/create-user.php" \
         --user "$ADMIN_USER_VALUE" \
         --password "$(get_env ADMIN_PASSWORD)" \
         --api-password "$(get_env ADMIN_API_PASSWORD)" \
         --email "$(get_env ADMIN_EMAIL)" \
         --language "$(get_env FRESHRSS_LANGUAGE en)" >/dev/null 2>&1; then
      ok "admin user created, API enabled"
    else
      warn "could not create the admin user from the CLI"
      dim "open http://127.0.0.1:$FR_PORT and use the web installer"
    fi
  fi
fi

# =============================================================================
# Done
# =============================================================================
FR_PORT="$(freshrss_port)"
RB_PORT="$(rssbridge_port)"

printf '\n'
ok "install complete"
printf '\n'
printf '  FreshRSS    http://127.0.0.1:%s\n' "$FR_PORT"
printf '  RSS-Bridge  http://127.0.0.1:%s\n' "$RB_PORT"
printf '\n'
printf '  %sNext:%s\n' "$C_BLUE" "$C_RESET"
printf '    1. ./scripts/healthcheck.sh          verify everything\n'
printf '    2. Open FreshRSS and enable API access + set the API password\n'
printf '       (Administration -> Authentication, then Profile)\n'
printf '    3. ./scripts/seed_menubar_config.sh  configure the menu bar app\n'
printf '    4. ./scripts/build.sh && open build/black_glass_candle.app\n'
printf '\n'
dim "All personal state lives outside the repo: $BGC_PRIVATE"
dim "The docroot is FreshRSS's own p/ directory, so your data is not web-reachable."
printf '\n'
