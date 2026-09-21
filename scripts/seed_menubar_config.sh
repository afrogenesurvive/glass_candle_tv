#!/usr/bin/env bash
# =============================================================================
# seed_menubar_config.sh — push .env values into the menu bar app
#
#   ./scripts/seed_menubar_config.sh
#   ./scripts/seed_menubar_config.sh --show      # show what is currently stored
#   ./scripts/seed_menubar_config.sh --clear     # remove stored credentials
#
# The Swift app never reads .env. It reads the Keychain (for the API password)
# and UserDefaults (for everything else). This script is the bridge between the
# two, so there is exactly one place to change the URL or rotate the password.
#
# Run this again after rotating ADMIN_API_PASSWORD.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

# Must match PrefsStore.bundleID in Sources/BlackGlassCandle/Store/PrefsStore.swift
BUNDLE_ID="com.afrogenesurvive.black-glass-candle"
KEYCHAIN_SERVICE="black_glass_candle"
KEYCHAIN_ACCOUNT="api-password"

MODE="seed"
while [ $# -gt 0 ]; do
  case "$1" in
    --show)  MODE="show" ;;
    --clear) MODE="clear" ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

command -v security >/dev/null 2>&1 || die "'security' not found — this script is macOS only"

# -----------------------------------------------------------------------------
# --show
# -----------------------------------------------------------------------------
if [ "$MODE" = "show" ]; then
  info "stored configuration"

  printf '\n  %sUserDefaults%s (domain: %s)\n' "$C_BLUE" "$C_RESET" "$BUNDLE_ID"
  for key in apiBaseURL apiUser refreshSeconds menuBarTextMode showFlameIndicator useEmbeddedWebView; do
    val="$(defaults read "$BUNDLE_ID" "$key" 2>/dev/null || echo "(unset)")"
    printf '    %-20s %s\n' "$key" "$val"
  done

  printf '\n  %sKeychain%s (service: %s)\n' "$C_BLUE" "$C_RESET" "$KEYCHAIN_SERVICE"
  if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
    LEN="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null | wc -c | tr -d ' ')"
    printf '    %-20s %s\n' "$KEYCHAIN_ACCOUNT" "present (${LEN} chars)"
    dim "value is deliberately not printed"
  else
    printf '    %-20s %s\n' "$KEYCHAIN_ACCOUNT" "(not set)"
  fi
  printf '\n'
  exit 0
fi

# -----------------------------------------------------------------------------
# --clear
# -----------------------------------------------------------------------------
if [ "$MODE" = "clear" ]; then
  info "clearing stored configuration"
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 \
    && ok "removed Keychain item" || dim "no Keychain item to remove"
  for key in apiBaseURL apiUser refreshSeconds menuBarTextMode showFlameIndicator useEmbeddedWebView; do
    defaults delete "$BUNDLE_ID" "$key" >/dev/null 2>&1 || true
  done
  ok "removed UserDefaults keys"
  printf '\n'
  dim "Quit and relaunch the app to see the change."
  printf '\n'
  exit 0
fi

# -----------------------------------------------------------------------------
# Seed
# -----------------------------------------------------------------------------
require_env_file

API_URL="$(get_env MENUBAR_API_BASE_URL)"
API_USER="$(get_env MENUBAR_API_USER "$(get_env ADMIN_USER admin)")"
API_PASS="$(get_env MENUBAR_API_PASSWORD)"
[ -n "$API_PASS" ] || API_PASS="$(get_env ADMIN_API_PASSWORD)"
REFRESH="$(get_env MENUBAR_REFRESH_SECONDS 300)"

[ -n "$API_URL" ]  || die "MENUBAR_API_BASE_URL is empty in .env"
[ -n "$API_USER" ] || die "MENUBAR_API_USER is empty in .env"
if [ -z "$API_PASS" ]; then
  die "no API password found.
       Set MENUBAR_API_PASSWORD (or ADMIN_API_PASSWORD) in .env.
       Both are blank in .env.example — see docs/inputs_required.md §B2."
fi

if [ "${#API_PASS}" -lt 8 ]; then
  warn "the API password is shorter than 8 characters; FreshRSS may reject it"
fi

info "seeding menu bar configuration"

# -----------------------------------------------------------------------------
# UserDefaults
# -----------------------------------------------------------------------------
defaults write "$BUNDLE_ID" apiBaseURL          -string "$API_URL"
defaults write "$BUNDLE_ID" apiUser             -string "$API_USER"
defaults write "$BUNDLE_ID" refreshSeconds      -int    "$REFRESH"
defaults write "$BUNDLE_ID" menuBarTextMode     -string "unread"
defaults write "$BUNDLE_ID" showFlameIndicator  -bool   true
defaults write "$BUNDLE_ID" useEmbeddedWebView  -bool   false
ok "UserDefaults written (domain: $BUNDLE_ID)"

# -----------------------------------------------------------------------------
# Keychain
# -----------------------------------------------------------------------------
# ADVISORY lock is used so a GUI challenge is not required for the first write;
# macOS may still prompt once when the app reads it back. That prompt is
# expected and should be answered "Always Allow".
if security add-generic-password \
      -s "$KEYCHAIN_SERVICE" \
      -a "$KEYCHAIN_ACCOUNT" \
      -l "black_glass_candle API password" \
      -D "application password" \
      -w "$API_PASS" \
      -U >/dev/null 2>&1; then
  ok "Keychain item written (service: $KEYCHAIN_SERVICE)"
else
  warn "could not write the Keychain item without a prompt"
  dim "run this instead, and paste the password at the prompt:"
  dim "  security add-generic-password -s $KEYCHAIN_SERVICE -a $KEYCHAIN_ACCOUNT -w"
fi

printf '\n'
ok "done"
printf '\n'
printf '  %sVerify%s\n' "$C_BLUE" "$C_RESET"
printf '    ./scripts/seed_menubar_config.sh --show\n'
printf '    curl -s -X POST -d "Email=%s&Passwd=<password>" "%s/accounts/ClientLogin"\n' \
  "$API_USER" "${API_URL%/}"
printf '\n'
dim "The curl should return a line beginning Auth=. If it returns Service"
dim "Unavailable, enable 'Allow API access' in FreshRSS under Authentication."
printf '\n'
dim "Quit and relaunch the app if it is already running."
printf '\n'
