#!/bin/zsh
# Renders the icon and rebuilds Resources/Icon/AppIcon.icns from it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift scripts/make_icon.swift Resources/Icon/icon-1024.png
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/Icon/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/Icon/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/Icon/AppIcon.icns
echo "Wrote Resources/Icon/AppIcon.icns"
