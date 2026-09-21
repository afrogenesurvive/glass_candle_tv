#!/bin/bash
# =============================================================================
# build.sh — build and package black_glass_candle.app
#
#   ./scripts/build.sh              # version from the current git branch
#   ./scripts/build.sh 0.2.0        # explicit version
#   ./scripts/build.sh --debug      # debug build, no .app bundle
#
# Follows the DS-mon convention: version comes from the branch name, build number
# from the commit count, and the .app is assembled by hand rather than by Xcode.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEBUG_BUILD=0
VERSION_ARG=""
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG_BUILD=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) VERSION_ARG="$arg" ;;
  esac
done

# -----------------------------------------------------------------------------
# Version
# -----------------------------------------------------------------------------
# Priority: explicit argument > branch name > fallback. DS-mon uses bare branch
# names as versions, which makes it obvious which build came from where.
if [ -n "$VERSION_ARG" ]; then
  VERSION="$VERSION_ARG"
elif BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null)" && [ -n "$BRANCH" ]; then
  VERSION="$BRANCH"
else
  VERSION="0.0.1"
fi
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
BUILD_VERSION="${VERSION}+${BUILD}"

APP="$ROOT/build/black_glass_candle.app"

echo "==> black_glass_candle  version $BUILD_VERSION"

if [ "$DEBUG_BUILD" -eq 1 ]; then
  echo "==> debug build"
  swift build
  echo "==> done. Run: .build/debug/black_glass_candle"
  exit 0
fi

# -----------------------------------------------------------------------------
# Compile
# -----------------------------------------------------------------------------
echo "==> swift build -c release"
# NOTE: -Onone is not a mistake. DS-mon carries the same workaround for the same
# toolchain: with -O and whole-module optimisation, Swift 6.3.3 silently drops
# some string literals, which shows up as blank labels in the UI rather than as a
# build error. This app is a menu bar item; the optimisation is irrelevant.
swift build -c release --disable-sandbox -Xswiftc -Onone

BIN="$(swift build -c release --show-bin-path)/black_glass_candle"
[ -f "$BIN" ] || { echo "error: binary not found at $BIN" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Bundle
# -----------------------------------------------------------------------------
echo "==> packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/black_glass_candle"
chmod +x "$APP/Contents/MacOS/black_glass_candle"

# Icon: generated, not committed. A missing icon is not fatal, so a failure here
# warns rather than aborting the build.
if command -v python3 >/dev/null 2>&1; then
  if python3 "$ROOT/scripts/gen_icon.py" "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
    echo "    icon generated"
  else
    echo "    warning: icon generation failed; building without one"
  fi
else
  echo "    warning: python3 not found; building without an icon"
fi

# -----------------------------------------------------------------------------
# Info.plist
# -----------------------------------------------------------------------------
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>black_glass_candle</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.afrogenesurvive.black-glass-candle</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>black_glass_candle</string>
	<key>CFBundleDisplayName</key>
	<string>black_glass_candle</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$BUILD_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<!-- Menu bar only: no Dock icon, no app switcher entry. -->
	<key>LSUIElement</key>
	<true/>
	<key>BGCCBuildTimestamp</key>
	<string>$(date '+%Y-%m-%d %H:%M:%S')</string>
	<key>NSHumanReadableCopyright</key>
	<string>MIT License. Copyright (c) 2026 AfroGeneSurvive</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<!--
		  Allows plain HTTP to local hosts, which is what a self-hosted FreshRSS
		  on 127.0.0.1 uses. Deliberately NOT NSAllowsArbitraryLoads: that would
		  permit cleartext HTTP to anywhere, which is a much wider hole than this
		  app needs.

		  If you host FreshRSS on a remote machine over plain HTTP (e.g. a
		  Tailscale address with no TLS), you will need to add
		  NSAllowsArbitraryLoads here yourself.
		-->
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST

# Refresh the bundle so Finder and LaunchServices pick up the new icon.
touch "$APP"

echo "==> done: $APP"
echo "    run:  open $APP"
echo ""
echo "    The app is unsigned, so the first launch needs right-click -> Open"
echo "    to clear Gatekeeper."
echo ""
echo "    Before launching, seed the connection settings:"
echo "      ./scripts/seed_menubar_config.sh"
