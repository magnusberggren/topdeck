#!/bin/bash
# Builds, signs and publishes a release that installed copies update to.
#   scripts/release.sh            release main as v1.<commit count>
# Needs: a Developer ID certificate and the `notary` profile (see
# scripts/package.sh), `gh` signed in, and a clean checkout of main that's pushed.
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

BUILD="$BUILD" scripts/package.sh

gh release create "$TAG" build/release/QuickFolder.dmg build/release/QuickFolder.zip --target "$(git rev-parse HEAD)" --title "QuickFolder 1.$BUILD" --generate-notes
echo "Released $TAG. Installed copies pick it up within 6 hours, or at once from ⋯ › Check for Updates…"
