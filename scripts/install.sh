#!/bin/bash
# Builds TopDeck, installs it in /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh
pkill -x TopDeck 2>/dev/null && sleep 0.5 || true
pkill -x QuickFolder 2>/dev/null && sleep 0.5 || true
# The app was called QuickFolder before.
rm -rf /Applications/TopDeck.app /Applications/QuickFolder.app
cp -R build/TopDeck.app /Applications/TopDeck.app
open /Applications/TopDeck.app
echo "TopDeck is running. Point at the notch."
