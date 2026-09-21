#!/usr/bin/env bash
# =============================================================================
# install-youlag.sh — install or update the Youlag FreshRSS extension
#
#   ./scripts/install-youlag.sh
#   ./scripts/install-youlag.sh --version v4.4.3
#
# Youlag turns YouTube feeds into a video-shaped layout instead of a list of
# links, and adds a miniplayer, screen-capture thumbnails and Shorts blocking.
#
# Requirements: FreshRSS >= 1.30.0. An older pinned clone breaks it silently.
#
# Downloaded, not vendored: it is GPL-3.0 third-party code and has no business in
# this repository. It lands in private/apps/FreshRSS/extensions/, which is
# gitignored along with the rest of private/.
# =============================================================================

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SELF_DIR/lib-common.sh"

REPO="civilblur/youlag"
VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) shift; [ $# -gt 0 ] || die "--version needs a value"; VERSION="$1" ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
  shift
done

require_private_dir

[ -d "$FRESHRSS_DIR" ] || die "FreshRSS is not installed. Run: ./scripts/install.sh"

command -v curl    >/dev/null 2>&1 || die "curl not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found (parses the GitHub release JSON)"
command -v unzip   >/dev/null 2>&1 || die "unzip not found"

EXT_DIR="$FRESHRSS_DIR/extensions"
DEST="$EXT_DIR/xExtension-Youlag"
mkdir -p "$EXT_DIR"

# -----------------------------------------------------------------------------
# 1. Resolve the release
# -----------------------------------------------------------------------------
if [ -n "$VERSION" ]; then
  info "looking up release $VERSION"
  API="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
else
  info "looking up the latest release of $REPO"
  API="https://api.github.com/repos/${REPO}/releases/latest"
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

HTTP="$(curl -s -o "$TMP/release.json" -w '%{http_code}' --max-time 20 "$API" || printf '000')"
[ "$HTTP" = "200" ] || die "GitHub API returned HTTP $HTTP
       If this is a rate limit, wait an hour and retry."

TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$TMP/release.json")"
ok "release $TAG"

# Prefer a .zip asset; fall back to the source zipball, which also contains the
# xExtension-Youlag directory.
ASSET_URL="$(python3 - "$TMP/release.json" <<'PY'
import json, sys
rel = json.load(open(sys.argv[1]))
for a in rel.get("assets", []):
    if a.get("name", "").lower().endswith(".zip"):
        print(a["browser_download_url"]); sys.exit()
print(rel.get("zipball_url", ""))
PY
)"
[ -n "$ASSET_URL" ] || die "no downloadable asset in release $TAG"

# -----------------------------------------------------------------------------
# 2. Download and extract
# -----------------------------------------------------------------------------
info "downloading $(basename "$ASSET_URL")"
curl -sL --max-time 120 -o "$TMP/pkg.zip" "$ASSET_URL" || die "download failed"
[ -s "$TMP/pkg.zip" ] || die "downloaded file is empty"
ok "$(human_bytes "$(wc -c < "$TMP/pkg.zip" | tr -d ' ')")"

info "extracting"
mkdir -p "$TMP/x"
unzip -q -o "$TMP/pkg.zip" -d "$TMP/x" || die "unzip failed"

SRC="$(find "$TMP/x" -maxdepth 4 -type d -name 'xExtension-Youlag' 2>/dev/null | head -n 1 || true)"
if [ -z "$SRC" ]; then
  # Some archives nest the extension contents directly rather than the folder.
  if [ -f "$TMP/x/metadata.json" ] && [ -f "$TMP/x/extension.php" ]; then
    SRC="$TMP/x"
  else
    die "no xExtension-Youlag directory found. Archive contained:
$(find "$TMP/x" -maxdepth 2 | sed 's/^/         /')"
  fi
fi
ok "found $(basename "$SRC")"

# -----------------------------------------------------------------------------
# 3. Install
# -----------------------------------------------------------------------------
read_version() {
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["version"])
except Exception: print("?")' "$1" 2>/dev/null || echo '?'
}

if [ -d "$DEST" ]; then
  info "replacing existing Youlag $(read_version "$DEST/metadata.json")"
  rm -rf "$DEST"
fi

cp -R "$SRC" "$DEST"
chmod -R u+rwX,go-w "$DEST" 2>/dev/null || true
ok "Youlag installed (v$(read_version "$DEST/metadata.json"))"
dim "$DEST"

# -----------------------------------------------------------------------------
# 4. Restart so FreshRSS picks it up
# -----------------------------------------------------------------------------
# FreshRSS caches extension assets, so installing without a restart (and then a
# hard browser reload) shows the old UI and looks like nothing happened.
if [ "$(agent_state freshrss)" = "running" ]; then
  info "restarting freshrss"
  "$SELF_DIR/services.sh" restart freshrss >/dev/null 2>&1 && ok "restarted"
else
  warn "freshrss is not running — start it before enabling the extension"
fi

printf '\n'
ok "Youlag $TAG installed"
printf '\n'
printf '  %sNext:%s\n' "$C_BLUE" "$C_RESET"
printf '    1. FreshRSS -> Settings -> Extensions\n'
printf '    2. Enable Youlag\n'
printf '    3. Hard-reload the browser (Cmd+Shift+R)\n'
printf '\n'
dim "Step 3 matters: the old UI will otherwise persist and make the install look"
dim "like it failed."
printf '\n'
dim "Requires FreshRSS >= 1.30.0 — check the version at the bottom of the About page."
printf '\n'
