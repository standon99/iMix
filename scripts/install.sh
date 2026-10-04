#!/bin/zsh
# Builds iMix and installs it to /Applications, so "Open at login" keeps pointing at a stable copy
# (build/iMix.app is deleted and re-signed on every build).
set -euo pipefail
cd "$(dirname "$0")/.."

NO_LAUNCH=1 ./scripts/run.sh
pkill -x iMix 2>/dev/null || true
rm -rf /Applications/iMix.app
cp -R build/iMix.app /Applications/iMix.app
open /Applications/iMix.app
echo "Installed /Applications/iMix.app"
