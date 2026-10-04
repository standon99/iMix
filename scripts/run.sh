#!/bin/zsh
# Builds iMix and wraps it in a .app bundle (needed for mic / audio-capture permissions), then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Release by default: the audio callback is several times too slow unoptimized.
CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="build/iMix.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/iMix" "$APP/Contents/MacOS/iMix"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

if [[ "${NO_LAUNCH:-0}" != "1" ]]; then
  pkill -x iMix 2>/dev/null || true
  open "$APP"
fi
echo "Built $APP"
