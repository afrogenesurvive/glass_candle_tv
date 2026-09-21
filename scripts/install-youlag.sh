#!/usr/bin/env bash
# =============================================================================
# install-youlag.sh — install or update the Youlag FreshRSS extension
#
#   ./scripts/install-youlag.sh
#   ./scripts/install-youlag.sh --version v4.4.3
#
# Youlag turns YouTube feeds into a video-shaped layout instead of a list of
# links. It also supplies a miniplayer, DeArrow-style thumbnails, and Shorts
# blocking.
#
# Requirements: FreshRSS >= 1.30.0. Pinning an older tag breaks it silently.
#
# The extension is downloaded, not vendored: it is GPL-3.0 third-party code and
# has no business in this repository.
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

EXT_DIR="$BGC_ROOT/freshrss-extensions"
DEST="$EXT_DIR/xExtension-Youlag"

command -v curl >/dev/null 2>&1 || die "curl not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found (used to parse the GitHub release JSON)"
command -v unzip >/dev/null 2>&1 || die "unzip not found"

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

TMPDIR_LOCAL="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_LOCAL"; }
trap cleanup EXIT INT TERM

HTTP="$(curl -s -o "$TMPDIR_LOCAL/release.json" -w '%{http_code}' --max-time 20 "$API" || printf '000')"
if [ "$HTTP" != "200" ]; then
  die "GitHub API returned HTTP $HTTP.
       If this is a rate limit, wait an hour or set a token:
         curl -H 'Authorization: Bearer \$GITHUB_TOKEN' ..."
fi

TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$TMPDIR_LOCAL/release.json")"
ok "release $TAG"

# Prefer a .zip asset; fall back to the source zipball (which also contains the
# xExtension-Youlag directory).
ASSET_URL="$(python3 - "$TMPDIR_LOCAL/release.json" <<'PY'
import json, sys
rel = json.load(open(sys.argv[1]))
for a in rel.get("assets", []):
    n = a.get("name", "").lower()
    if n.endswith(".zip"):
        print(a["browser_download_url"]); sys.exit()
print(rel.get("zipball_url", ""))
PY
)"

[ -n "$ASSET_URL" ] || die "no downloadable asset found in release $TAG"

# -----------------------------------------------------------------------------
# 2. Download
# -----------------------------------------------------------------------------
info "downloading $(basename "$ASSET_URL")"
curl -sL --max-time 120 -o "$TMPDIR_LOCAL/pkg.zip" "$ASSET_URL" \
  || die "download failed"
[ -s "$TMPDIR_LOCAL/pkg.zip" ] || die "downloaded file is empty"
ok "$(human_bytes "$(wc -c < "$TMPDIR_LOCAL/pkg.zip" | tr -d ' ')")"

# -----------------------------------------------------------------------------
# 3. Extract and locate xExtension-Youlag
# -----------------------------------------------------------------------------
info "extracting"
mkdir -p "$TMPDIR_LOCAL/x"
unzip -q -o "$TMPDIR_LOCAL/pkg.zip" -d "$TMPDIR_LOCAL/x" || die "unzip failed"

SRC="$(find "$TMPDIR_LOCAL/x" -type d -name 'xExtension-Youlag' -maxdepth 4 2>/dev/null | head -n 1 || true)"
if [ -z "$SRC" ]; then
  # Some archives nest the extension contents directly.
  if [ -f "$TMPDIR_LOCAL/x/metadata.json" ] && [ -f "$TMPDIR_LOCAL/x/extension.php" ]; then
    SRC="$TMPDIR_LOCAL/x"
  else
    die "no xExtension-Youlag directory found in the archive.
       Contents were:
$(find "$TMPDIR_LOCAL/x" -maxdepth 2 | sed 's/^/         /')"
  fi
fi
ok "found $(basename "$SRC")"

# -----------------------------------------------------------------------------
# 4. Install
# -----------------------------------------------------------------------------
if [ -d "$DEST" ]; then
  OLD_VER="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["version"])
except Exception: print("?")' "$DEST/metadata.json" 2>/dev/null || echo '?')"
  info "replacing existing Youlag $OLD_VER"
  rm -rf "$DEST"
fi

cp -R "$SRC" "$DEST"
ok "installed to freshrss-extensions/xExtension-Youlag"

NEW_VER="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["version"])
except Exception: print("?")' "$DEST/metadata.json" 2>/dev/null || echo '?')"

# -----------------------------------------------------------------------------
# 5. Confirm FreshRSS version satisfies the requirement
# -----------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if compose ps --status running --services 2>/dev/null | grep -q '^freshrss$'; then
    info "restarting freshrss so the extension is picked up"
    compose restart freshrss >/dev/null && ok "restarted"
  else
    warn "freshrss is not running — start it before enabling the extension"
  fi
fi

printf '\n'
ok "Youlag $TAG installed"
printf '\n'
printf '  %sNext:%s\n' "$C_BLUE" "$C_RESET"
printf '    1. FreshRSS -> Settings -> Extensions\n'
printf '    2. Enable  Youlag\n'
printf '    3. Hard-reload the browser (Cmd+Shift+R)\n'
printf '\n'
dim "Step 3 matters: FreshRSS caches extension assets, so a normal reload shows"
dim "the old UI and makes it look like the install did nothing."
printf '\n'
dim "Requires FreshRSS >= 1.30.0. If YouTube mode does nothing, check the version"
dim "shown at the bottom of FreshRSS -> About."
printf '\n'
