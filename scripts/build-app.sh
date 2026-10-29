#!/usr/bin/env bash
# Builds BarPulse.app into ./build and code-signs it.
#
#   CONFIG=debug scripts/build-app.sh          # debug build
#   CODESIGN_IDENTITY=- scripts/build-app.sh   # force ad-hoc signing
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/BarPulse.app"
cd "$ROOT"

swift build -c "$CONFIG" --product BarPulse
BIN="$(swift build -c "$CONFIG" --show-bin-path)/BarPulse"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BarPulse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# A stable identity keeps launch-at-login and other TCC state across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
fi
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP (signed with: $IDENTITY)"
