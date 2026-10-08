#!/bin/bash
# Builds the files a release ships, notarized by Apple so they open on any
# Mac without warnings:
#   build/release/TopDeck.dmg   for people: open it, drag to Applications
#   build/release/TopDeck.zip   for the built-in updater
# Needs a Developer ID certificate and the `notary` keychain profile:
#   xcrun notarytool store-credentials notary --apple-id <Apple ID> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/release"
APP="build/TopDeck.app"
PROFILE="${NOTARY_PROFILE:-notary}"

TIMESTAMP=1 scripts/build.sh
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
case "$IDENTITY" in
  "Developer ID Application"*) ;;
  *) echo "Not signed with a Developer ID certificate; other Macs won't open it." >&2; exit 1 ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT"

notarize() {
  echo "Notarizing $(basename "$1") (usually a minute or two)…"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m
}

# 1. The app: notarize, then staple the ticket so it opens even offline.
ditto -c -k --keepParent "$APP" "$OUT/submit.zip"
notarize "$OUT/submit.zip"
xcrun stapler staple "$APP"
rm "$OUT/submit.zip"
ditto -c -k --keepParent "$APP" "$OUT/TopDeck.zip"
# Copies from before the rename look for QuickFolder.zip holding QuickFolder.app.
# They install it under the old name, and it renames itself on first launch.
LEGACY="$(mktemp -d)"
cp -R "$APP" "$LEGACY/QuickFolder.app"
ditto -c -k --keepParent "$LEGACY/QuickFolder.app" "$OUT/QuickFolder.zip"
rm -rf "$LEGACY"

# 2. The disk image: the app next to an Applications shortcut.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TopDeck" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT/TopDeck.dmg" >/dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$OUT/TopDeck.dmg"
notarize "$OUT/TopDeck.dmg"
xcrun stapler staple "$OUT/TopDeck.dmg"

# What Gatekeeper will say on someone else's Mac.
spctl --assess --type execute "$APP"
spctl --assess --type open --context context:primary-signature "$OUT/TopDeck.dmg"
echo "Ready: $OUT/TopDeck.dmg and $OUT/TopDeck.zip ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"))"
