#!/bin/bash
# Builds QuickFolder, installs it in /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh
pkill -x QuickFolder 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/QuickFolder.app
cp -R build/QuickFolder.app /Applications/QuickFolder.app
open /Applications/QuickFolder.app
echo "QuickFolder is running. Point at the notch."
