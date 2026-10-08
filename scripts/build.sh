#!/bin/bash
# Builds build/QuickFolder.app.
#   scripts/build.sh            release build
#   CONFIG=debug scripts/build.sh
#   SIGN_IDENTITY="-" scripts/build.sh   ad-hoc signing
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/QuickFolder.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/QuickFolder" "$APP/Contents/MacOS/QuickFolder"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The build number is the commit count, so every build on main is newer than
# the last. The updater compares it with the release tag (v1.<build>).
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" -c "Set :CFBundleShortVersionString 1.$BUILD" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Downloads permission across rebuilds.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Apple Development|Developer ID Application)' | head -1 \
    | sed -E 's/.*"(.*)"/\1/')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
codesign --force --options runtime --entitlements Resources/QuickFolder.entitlements --sign "$SIGN_IDENTITY" "$APP" >/dev/null
echo "Built $APP (signed with: $SIGN_IDENTITY)"
