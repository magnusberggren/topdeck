#!/bin/bash
# Builds build/TopDeck.app.
#   scripts/build.sh            release build
#   CONFIG=debug scripts/build.sh
#   SIGN_IDENTITY="-" scripts/build.sh   ad-hoc signing
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/TopDeck.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TopDeck" "$APP/Contents/MacOS/TopDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The build number is the commit count, so every build on main is newer than
# the last. The updater compares it with the release tag (v1.<build>).
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" -c "Set :CFBundleShortVersionString 1.$BUILD" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The Developer ID certificate that expires last, so a renewed (or company)
# certificate wins over an older one. Prints its SHA-1, or nothing.
newest_developer_id() {
  local valid hash best="" best_end=0 pem end
  valid="$(security find-identity -v -p codesigning 2>/dev/null)"
  while read -r hash; do
    pem="$(security find-certificate -a -Z -p -c "Developer ID Application" 2>/dev/null \
      | awk -v h="$hash" '/^SHA-1 hash:/ {on = ($3 == h)} on && /BEGIN/,/END/ {if (on) print}')"
    end="$(echo "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    end="$(date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null || echo 0)"
    if [ "$end" -gt "$best_end" ]; then best="$hash"; best_end="$end"; fi
  done < <(echo "$valid" | grep '"Developer ID Application' | awk '{print $2}')
  echo "$best"
}

# A stable signing identity keeps the Downloads permission across rebuilds.
# Every certificate from the same team counts as the same app to macOS, so
# switching between them keeps permissions and updates working.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(newest_developer_id)"
  if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | grep '"Apple Development' | head -1 | sed -E 's/.*"(.*)"/\1/')"
  fi
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
# Notarization needs a secure timestamp, which takes a round trip to Apple,
# so only release packaging asks for one.
TIMESTAMP_FLAG="--timestamp=none"
[ "${TIMESTAMP:-0}" = "1" ] && TIMESTAMP_FLAG="--timestamp"
codesign --force --options runtime $TIMESTAMP_FLAG --entitlements Resources/TopDeck.entitlements --sign "$SIGN_IDENTITY" "$APP" >/dev/null
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "Built $APP (signed with: ${AUTHORITY:-ad-hoc})"
