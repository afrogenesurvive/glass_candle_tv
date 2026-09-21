#!/usr/bin/env bash
# =============================================================================
# gen-configs.sh — generate service config from private/env
#
#   ./scripts/gen-configs.sh            # write configs
#   ./scripts/gen-configs.sh --dry-run  # print to stdout instead
#
# There is no web server to configure. FreshRSS is served by PHP's built-in
# server with its docroot set to the app's own p/ directory, which is exactly
# what FreshRSS's documentation asks for:
#
#   "For better security, expose only the ./p/ folder to the Web. Be aware that
#    the ./data/ folder contains all personal data, so it is a bad idea to
#    expose it."
#
# Because data/ is a sibling of p/, it is not in the served tree at all. That is
# structural rather than a rule that could be misconfigured.
#
# RSS-Bridge is different: its own root has to be the docroot, and that root
# contains config.ini.php (the token) plus a cache directory. So it gets a
# router script that permits exactly two paths and 404s everything else.
#
# Writes, all inside private/ and therefore gitignored:
#   private/etc/rss-bridge-router.php
#   private/apps/rss-bridge/config.ini.php
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

DRY_RUN=0
case "${1-}" in
  --dry-run|-n) DRY_RUN=1 ;;
  -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) die "unknown argument: $1" ;;
esac

require_env_file
require_private_dir
require_vars ADMIN_USER

ROUTER="$ETC_DIR/rss-bridge-router.php"
# NOTE: the repository ROOT, not config/. `config/config.ini.php` is the Docker
# image's convention, where /config is a mount point. A native clone reads
# `config.ini.php` from its own root directory, and if the file is in the wrong
# place RSS-Bridge does not complain — it simply runs with defaults, which means
# token authentication is silently OFF while everything else looks healthy.
RSSBRIDGE_CONF="$RSSBRIDGE_DIR/config.ini.php"

mkdir -p "$ETC_DIR" "$RUN_DIR" "$LOGS_DIR" "$APPS_DIR"

write_or_print() {
  local dest="$1" rendered
  rendered="$(cat)"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n%s===== %s =====%s\n' "$C_DIM" "${dest#"$BGC_ROOT"/}" "$C_RESET"
    printf '%s\n' "$rendered"
    return
  fi
  # Write via a temp file in the same directory so an interrupted run cannot
  # leave a half-written config behind.
  local tmp
  tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")"
  printf '%s\n' "$rendered" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$dest"
  ok "wrote ${dest#"$BGC_ROOT"/}"
}

# =============================================================================
# RSS-Bridge router
# =============================================================================
# PHP's built-in server serves any non-.php file in the docroot as a static
# asset. RSS-Bridge's docroot contains config.ini.php (the shared token),
# a cache directory, and the application source. Routing every request through
# this file means only two paths are reachable and nothing else is ever served.
#
# `config.ini.php` would in practice be harmless if requested directly — its
# first line is `; <?php exit; ?>`, so PHP executes it and stops — but relying on
# that as the only control is a single point of failure. This is explicit.
# =============================================================================
router_template() {
  cat <<'PHP'
<?php
declare(strict_types=1);

/**
 * GENERATED FILE — do not edit.
 * Source of truth: private/env   Regenerate: ./scripts/gen-configs.sh
 *
 * Router for the PHP built-in server in front of RSS-Bridge.
 *
 * Returning false tells the built-in server to handle the request normally
 * (execute the .php file, or serve the static asset). Returning true means the
 * router already produced the response.
 */

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);

if (!is_string($path) || $path === '') {
    $path = '/';
}

// 1. Everything RSS-Bridge does funnels through index.php at the root. All feed
//    URLs look like /?action=display&bridge=...&format=...&token=...
if ($path === '/' || $path === '/index.php') {
    return false;
}

// 2. Static assets, which RSS-Bridge serves from /static/.
if (str_starts_with($path, '/static/')) {
    // Reject traversal before delegating. The built-in server normalises paths,
    // but this is cheap and makes the intent explicit.
    if (str_contains($path, '..')) {
        http_response_code(403);
        return true;
    }
    return false;
}

// 3. Anything else — config/, cache/, bridges/, vendor/, composer.json — is not
//    public.
http_response_code(404);
header('Content-Type: text/plain; charset=utf-8');
echo "Not found\n";
return true;
PHP
}

# =============================================================================
# RSS-Bridge config.ini.php
# =============================================================================
rssbridge_template() {
  local token="$1" bridges="$2" cache_duration="$3" useragent="$4"
  local ig_session="$5" ig_user="$6" gh_token="$7"
  printf '%s\n' '; <?php exit; ?> DO NOT REMOVE THIS LINE'
  printf '%s\n' '; ---------------------------------------------------------------------------'
  printf '%s\n' '; GENERATED FILE - do not edit.'
  printf '%s\n' '; Source of truth: private/env   Regenerate: ./scripts/gen-configs.sh'
  printf '; Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '%s\n' '; ---------------------------------------------------------------------------'
  printf '\n'
  printf '%s\n' '[authentication]'
  printf '%s\n' '; Every feed URL must carry &token=<this value>. Without it this service is an'
  printf '%s\n' '; open, unauthenticated URL fetcher reachable by anything on this machine.'
  printf 'token = "%s"\n' "$token"
  printf '\n'
  printf '%s\n' '[error]'
  printf '%s\n' '; "http" keeps transient bridge failures out of the feed as fake articles.'
  printf '%s\n' 'output = "http"'
  printf '%s\n' 'report_limit = 3'
  printf '\n'
  printf '%s\n' '[cache]'
  printf '%s\n' '; Long enough that a twice-hourly refresh never causes a redundant upstream'
  printf '%s\n' '; request, short enough that new posts appear promptly.'
  printf '%s\n' 'type = "file"'
  printf 'duration = %s\n' "$cache_duration"
  printf '\n'
  printf '%s\n' '[system]'
  printf '%s\n' '; Bridge allowlist. Least privilege: several of the 400+ upstream bridges make'
  printf '%s\n' '; outbound requests on your behalf.'
  printf '%s\n' ';'
  printf '%s\n' '; These keys MUST stay under [system]. BridgeFactory reads'
  printf '%s\n' '; Configuration::getConfig("system", "enabled_bridges"). A bare'
  printf '%s\n' '; enabled_bridges[] line placed above any section header is parsed as belonging'
  printf '%s\n' '; to the section preceding it, so the allowlist silently does nothing and the'
  printf '%s\n' '; upstream default (every bridge) stays in force — while the file still looks'
  printf '%s\n' '; like it restricts them.'
  # NOTE: `printf '%s\n'` (WITH the newline) is required. With `printf '%s'` the
  # final item has no line terminator, `read` returns non-zero at EOF, and the
  # loop body never runs for it — silently dropping the last bridge.
  printf '%s\n' "$bridges" | tr ',' '\n' | while IFS= read -r b; do
    b="$(printf '%s' "$b" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$b" ] || continue
    printf 'enabled_bridges[] = %s\n' "$b"
  done

  # Credentials. Bridges that declare a CONFIGURATION constant read those keys
  # from a section named after the bridge's own short class name — see
  # BridgeAbstract::loadConfiguration(). Only keys a bridge actually declares can
  # have any effect, which is why this is a short, verified list rather than a
  # mirror of every credential in the env file.
  if [ -n "$useragent" ]; then
    printf '\n'
    printf '%s\n' '[http]'
    printf '%s\n' '; Default outbound User-Agent. Read by bridges that build their own'
    printf '%s\n' '; requests, e.g. FB2Bridge.'
    printf 'useragent = "%s"\n' "$useragent"
  fi

  if [ -n "$ig_session" ] && [ -n "$ig_user" ]; then
    printf '\n'
    printf '%s\n' '[InstagramBridge]'
    printf '%s\n' '; Burner-account cookies. InstagramBridge declares session_id and'
    printf '%s\n' '; ds_user_id; csrftoken is NOT a supported option, so it is not emitted.'
    printf 'session_id = "%s"\n' "$ig_session"
    printf 'ds_user_id = "%s"\n' "$ig_user"
  fi

  if [ -n "$gh_token" ]; then
    printf '\n'
    printf '%s\n' '[GithubReleaseBridge]'
    printf '%s\n' '; Raises the GitHub API rate limit from 60/hr to 5000/hr.'
    printf 'token = "%s"\n' "$gh_token"
  fi

  printf '\n'
  printf '%s\n' '; Custom bridges placed in this directory are picked up automatically.'
}

# =============================================================================
# Run
# =============================================================================
FR_PORT="$(freshrss_port)"
RB_PORT="$(rssbridge_port)"

info "generating config"
dim "data dir    $BGC_PRIVATE"
dim "freshrss    http://127.0.0.1:$FR_PORT   (docroot: ${FRESHRSS_DIR#"$BGC_PRIVATE"/}/p)"
dim "rss-bridge  http://127.0.0.1:$RB_PORT   (docroot: ${RSSBRIDGE_DIR#"$BGC_PRIVATE"/})"
dim "workers     $(php_cli_workers)"
dim "timezone    $(get_env TZ UTC)"

router_template | write_or_print "$ROUTER"

if [ -d "$RSSBRIDGE_DIR" ]; then
  RSSBRIDGE_TOKEN="$(get_env RSSBRIDGE_TOKEN)"
  # Instagram is the one source requiring full account credentials, so its
  # cookies are only emitted when the source is deliberately switched on.
  IG_SESSION='' IG_USER=''
  if [ "$(get_env ENABLE_INSTAGRAM 0)" = "1" ]; then
    IG_SESSION="$(get_env INSTAGRAM_SESSIONID)"
    IG_USER="$(get_env INSTAGRAM_DS_USER_ID)"
  fi
  if [ -z "$RSSBRIDGE_TOKEN" ]; then
    warn "RSSBRIDGE_TOKEN is empty — skipping the RSS-Bridge config"
    dim "generate one:  openssl rand -hex 24"
  else
    # Default allowlist contains only bridges that actually ship with
    # RSS-Bridge. Verified against the clone's bridges/ directory — several names
    # in common circulation (HackerNewsBridge, LemmyBridge, BearBlogBridge,
    # GitHubBridge) do NOT exist, and an unknown name is simply ignored, so a
    # wrong list fails silently rather than loudly.
    #
    # Note Hacker News has no usable bridge any more; use the native feed
    # https://hnrss.org/frontpage instead. See docs/source_catalog.md.
    rssbridge_template \
      "$RSSBRIDGE_TOKEN" \
      "$(get_env RSSBRIDGE_ENABLED_BRIDGES 'CssSelectorBridge,RedditBridge,FeedMergeBridge,FilterBridge,FeedReducerBridge,GithubReleaseBridge,GithubTrendingBridge')" \
      "$(get_env RSSBRIDGE_CACHE_DURATION 3600)" \
      "$(get_env RSSBRIDGE_USER_AGENT)" \
      "$IG_SESSION" \
      "$IG_USER" \
      "$(get_env GITHUB_TOKEN)" \
      | write_or_print "$RSSBRIDGE_CONF"
  fi
else
  dim "rss-bridge is not cloned yet — skipping its config (install.sh does this)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\n'
  info "dry run complete — no files were written"
  exit 0
fi

printf '\n'
ok "config generated"
printf '\n'
dim "Restart to apply:  ./scripts/services.sh restart"
printf '\n'
