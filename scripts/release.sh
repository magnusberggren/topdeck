#!/bin/bash
# Builds, signs and publishes a release that installed copies update to.
#   scripts/release.sh            release main as v1.<commit count>
# Needs: a Developer ID certificate in the keychain, `gh` signed in, and a
# clean checkout of main that's pushed.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "Commit or stash your changes first." >&2; exit 1
fi
git fetch -q origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Release from main, matching origin/main." >&2; exit 1
fi

BUILD="$(git rev-list --count HEAD)"
TAG="v1.$BUILD"
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "$TAG is already released." >&2; exit 1
fi

BUILD="$BUILD" scripts/build.sh
codesign --verify --strict --deep build/QuickFolder.app
if ! codesign -dvv build/QuickFolder.app 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "Not signed with a Developer ID certificate; other Macs won't accept it." >&2; exit 1
fi

ZIP="build/QuickFolder.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/QuickFolder.app "$ZIP"

gh release create "$TAG" "$ZIP" --target "$(git rev-parse HEAD)" --title "QuickFolder 1.$BUILD" --generate-notes
echo "Released $TAG. Installed copies pick it up within 6 hours, or at once from ⋯ › Check for Updates…"
