#!/usr/bin/env bash
# =============================================================================
# services.sh — manage the launchd agents for glass_candle_tv
#
#   ./scripts/services.sh install     # write plists + load them
#   ./scripts/services.sh uninstall   # unload + remove plists
#   ./scripts/services.sh start       # start all (or one)
#   ./scripts/services.sh stop        # stop all (or one)
#   ./scripts/services.sh restart     # restart all (or one)
#   ./scripts/services.sh status      # what is running, and is it answering
#
# Services: freshrss | rssbridge | refresh   ("all" is the default)
#
# Everything is a user-level LaunchAgent, so nothing here needs sudo and nothing
# is installed system-wide.
#
# Why launchd rather than `brew services`: this deployment runs PHP's built-in
# server, not a Homebrew-managed service, so there is nothing for `brew services`
# to manage. LaunchAgents also survive a `brew upgrade php`.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

ALL_SERVICES="freshrss rssbridge refresh"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }
[ $# -ge 1 ] || { usage; exit 0; }

ACTION="$1"; shift || true
TARGET="${1:-all}"

# launchd starts agents with a minimal environment. Without an explicit PATH the
# php binary cannot resolve anything it shells out to, and Homebrew's prefix is
# not on the default PATH.
PLIST_PATH_ENV="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

write_plist() {
  local name="$1" xml="$2" dest
  dest="$(plist_path "$name")"
  mkdir -p "$LAUNCH_AGENTS_DIR"
  printf '%s' "$xml" > "$dest"
  chmod 644 "$dest"
  ok "wrote $(basename "$dest")"
}

plist_header() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
XML
}

plist_common() {
  local name="$1" extra_env="${2-}"
  cat <<XML
	<key>WorkingDirectory</key>
	<string>$BGC_PRIVATE</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$PLIST_PATH_ENV</string>
$extra_env	</dict>
	<key>StandardOutPath</key>
	<string>$LOGS_DIR/$name-stdout.log</string>
	<key>StandardErrorPath</key>
	<string>$LOGS_DIR/$name-stderr.log</string>
	<key>ProcessType</key>
	<string>Background</string>
XML
}

# -----------------------------------------------------------------------------
# A PHP built-in server agent
# -----------------------------------------------------------------------------
# Arguments shared by both apps:
#
#   -d date.timezone=<TZ>     the native equivalent of Docker's TZ variable.
#                             Without it PHP falls back to UTC and every feed
#                             timestamp is shifted.
#   -d memory_limit=256M      FreshRSS with a large feed database needs headroom.
#   -t <docroot>              what is actually served. For FreshRSS this is the
#                             app's p/ folder, which is what keeps data/ off the
#                             web. See scripts/gen-configs.sh.
#
# A router script is appended for RSS-Bridge only. FreshRSS does not need one:
# its docroot already contains nothing but public files.
plist_php_server() {
  local name="$1" port="$2" docroot="$3" router="${4-}" label
  label="$(label_for "$name")"

  # PHP_CLI_SERVER_WORKERS must be in the environment, not a -d flag: it is read
  # by the CLI server at startup, before any ini setting would apply.
  local extra_env
  extra_env="		<key>PHP_CLI_SERVER_WORKERS</key>
		<string>$(php_cli_workers)</string>
"

  {
    plist_header
    cat <<XML
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$PHP_BIN</string>
		<string>-S</string>
		<string>127.0.0.1:$port</string>
		<string>-d</string>
		<string>date.timezone=$(get_env TZ UTC)</string>
		<string>-d</string>
		<string>memory_limit=256M</string>
		<string>-t</string>
		<string>$docroot</string>
XML
    if [ -n "$router" ]; then
      cat <<XML
		<string>$router</string>
XML
    fi
    cat <<'XML'
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
XML
    plist_common "$name" "$extra_env"
    cat <<'XML'
</dict>
</plist>
XML
  }
}

# -----------------------------------------------------------------------------
# Agent scripts — staged OUT of the repository
# -----------------------------------------------------------------------------
# A launchd job cannot read a repository kept under ~/Documents, ~/Desktop or
# ~/Downloads: the read fails with "Operation not permitted" and the agent
# records exit 126, which is indistinguishable from a job that currently has
# nothing to do (the measurement is in lib-common.sh). The repo keeps the real,
# edited scripts; launchd runs copies from AGENT_DIR, which sits beside the data.
#
# Consequence worth knowing: editing refresh-feeds.sh in the repo does NOT change
# what the schedule runs. Re-running `install` is what deploys it — which is why
# healthcheck.sh reports a stale copy rather than trusting anyone to remember.
stage_agent_files() {
  local f
  mkdir -p "$AGENT_DIR" || die "could not create $AGENT_DIR"
  for f in $AGENT_FILES; do
    [ -f "$SELF_DIR/$f" ] || die "missing $SELF_DIR/$f"
    if [ -f "$AGENT_DIR/$f" ] && cmp -s "$SELF_DIR/$f" "$AGENT_DIR/$f"; then
      dim "$f unchanged"
    else
      cp -f "$SELF_DIR/$f" "$AGENT_DIR/$f" || die "could not stage $f"
      ok "staged $f"
    fi
  done
  chmod 700 "$AGENT_DIR" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# refresh (the native replacement for Docker's CRON_MIN)
# -----------------------------------------------------------------------------
# The Docker image ran a cron daemon driven by CRON_MIN="13,43" — "at minute 13
# and 43 of every hour". launchd expresses that as an ARRAY of
# StartCalendarInterval dicts, so the existing private/env value carries over
# unchanged instead of forcing a new setting.
refresh_calendar_entries() {
  local spec="$1" m out=''
  for m in $(printf '%s' "$spec" | tr ',' ' '); do
    case "$m" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$m" -ge 0 ] && [ "$m" -le 59 ]; then
      out="${out}		<dict><key>Minute</key><integer>${m}</integer></dict>
"
    fi
  done
  printf '%s' "$out"
}

plist_refresh() {
  local cron_min entries
  cron_min="$(get_env CRON_MIN '13,43')"
  entries="$(refresh_calendar_entries "$cron_min")"

  {
    plist_header
    cat <<XML
	<key>Label</key>
	<string>$(label_for refresh)</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$AGENT_DIR/refresh-feeds.sh</string>
		<string>--quiet</string>
	</array>
	<key>RunAtLoad</key>
	<false/>
	<!-- A one-shot job must NOT be KeepAlive'd: launchd would treat every normal
	     exit as a crash and re-run it continuously. -->
	<key>KeepAlive</key>
	<false/>
XML
    if [ -n "$entries" ]; then
      cat <<XML
	<key>StartCalendarInterval</key>
	<array>
$entries	</array>
XML
    else
      # An unparseable CRON_MIN must not become a job that never fires.
      cat <<'XML'
	<key>StartInterval</key>
	<integer>1800</integer>
XML
    fi
    plist_common "refresh"
    cat <<'XML'
</dict>
</plist>
XML
  }
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------
services_for() {
  case "$1" in
    all) printf '%s' "$ALL_SERVICES" ;;
    freshrss|rssbridge|refresh) printf '%s' "$1" ;;
    *) die "unknown service '$1'. Use: all | freshrss | rssbridge | refresh" ;;
  esac
}

do_install() {
  require_private_dir
  require_env_file
  require_php

  [ -d "$FRESHRSS_DIR" ] || die "FreshRSS is not installed. Run: ./scripts/install.sh"
  [ -f "$ETC_DIR/rss-bridge-router.php" ] || die "no generated config yet.
       Run: ./scripts/gen-configs.sh"

  info "installing launch agents"
  stage_agent_files

  write_plist freshrss  "$(plist_php_server freshrss  "$(freshrss_port)"  "$FRESHRSS_DIR/p")"
  write_plist rssbridge "$(plist_php_server rssbridge "$(rssbridge_port)" "$RSSBRIDGE_DIR" "$ETC_DIR/rss-bridge-router.php")"
  write_plist refresh   "$(plist_refresh)"

  local svc
  for svc in $ALL_SERVICES; do
    bootstrap_agent "$svc"
    ok "$svc loaded"
  done

  printf '\n'
  dim "launchd executes its scripts from $AGENT_DIR"
  dim "after editing anything in scripts/, re-run this command to deploy it"
  printf '\n'
  do_status
}

do_uninstall() {
  info "removing launch agents"
  local svc p
  for svc in $ALL_SERVICES; do
    bootout_agent "$svc"
    p="$(plist_path "$svc")"
    if [ -f "$p" ]; then
      rm -f "$p"
      ok "removed $(basename "$p")"
    else
      dim "$svc was not installed"
    fi
  done
  printf '\n'
  dim "Nothing in the data directory was deleted — your data is untouched:"
  dim "  $BGC_PRIVATE"
  printf '\n'
}

do_start() {
  local svc
  for svc in $(services_for "$TARGET"); do
    if [ ! -f "$(plist_path "$svc")" ]; then
      warn "$svc has no plist — run: ./scripts/services.sh install"
      continue
    fi
    if agent_loaded "$svc"; then
      launchctl kickstart "gui/$(id -u)/$(label_for "$svc")" >/dev/null 2>&1 || true
      ok "$svc started"
    else
      bootstrap_agent "$svc"
      ok "$svc loaded"
    fi
  done
}

do_stop() {
  local svc
  for svc in $(services_for "$TARGET"); do
    if agent_loaded "$svc"; then
      # bootout, not `kickstart -k`: with KeepAlive set, a kickstart would
      # immediately bring the process back up.
      bootout_agent "$svc"
      ok "$svc stopped"
    else
      dim "$svc was not running"
    fi
  done
}

do_restart() {
  local svc p
  # TZ, CRON_MIN, the ports and PHP_CLI_SERVER_WORKERS are baked into the plist
  # XML when it is generated, so a restart re-reads the FILE, not private/env.
  # Changing any of them needs `install`. Say so rather than silently keeping
  # the old values while reporting success.
  p="$(plist_path freshrss)"
  if [ -f "$p" ] && [ -f "$ENV_FILE" ] && [ "$p" -ot "$ENV_FILE" ]; then
    warn "private/env is newer than the launch agent plists"
    dim "  TZ, CRON_MIN, ports and worker counts are baked in at install time,"
    dim "  so a restart will not pick them up. Use: ./scripts/services.sh install"
  fi
  for svc in $(services_for "$TARGET"); do
    bootout_agent "$svc"
    if [ -f "$(plist_path "$svc")" ]; then
      bootstrap_agent "$svc"
      ok "$svc restarted"
    else
      warn "$svc has no plist"
    fi
  done
}

do_status() {
  info "service status"
  printf '\n'
  local svc state
  for svc in $ALL_SERVICES; do
    state="$(agent_state "$svc")"
    printf '  %-10s %s\n' "$svc" "$state"
  done
  printf '\n'

  local fr_port rb_port code
  fr_port="$(freshrss_port)"
  rb_port="$(rssbridge_port)"

  code="$(http_code "http://127.0.0.1:$fr_port/")"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    ok "FreshRSS answering on :$fr_port (HTTP $code)"
  elif [ "$code" = "000" ]; then
    warn "FreshRSS not answering on :$fr_port"
  else
    warn "FreshRSS returned HTTP $code on :$fr_port"
  fi

  code="$(http_code "http://127.0.0.1:$rb_port/")"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    ok "RSS-Bridge answering on :$rb_port (HTTP $code)"
  elif [ "$code" = "401" ]; then
    # Expected, not a fault: the root page needs the token, so a probe without
    # one is rejected. healthcheck.sh asks the same question with a valid token.
    ok "RSS-Bridge answering on :$rb_port (HTTP 401 — token auth enforced)"
  elif [ "$code" = "000" ]; then
    warn "RSS-Bridge not answering on :$rb_port"
  else
    warn "RSS-Bridge returned HTTP $code on :$rb_port"
  fi

  printf '\n'
  dim "Data: $BGC_PRIVATE"
  dim "Logs: $LOGS_DIR"
  printf '\n'
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  start)     do_start ;;
  stop)      do_stop ;;
  restart)   do_restart ;;
  status)    do_status ;;
  -h|--help) usage ;;
  *) die "unknown action '$ACTION'. Use: install | uninstall | start | stop | restart | status" ;;
esac
