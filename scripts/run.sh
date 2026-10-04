#!/bin/zsh
# Builds SoundStage and wraps it in a .app bundle (needed for mic / audio-capture permissions), then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Release by default: the audio callback is several times too slow unoptimized.
CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="build/SoundStage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/SoundStage" "$APP/Contents/MacOS/SoundStage"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null

if [[ "${NO_LAUNCH:-0}" != "1" ]]; then
  pkill -x SoundStage 2>/dev/null || true
  open "$APP"
fi
echo "Built $APP"
