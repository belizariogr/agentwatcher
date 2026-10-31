#!/bin/bash
# Render the DMG artwork in Resources/dmg (committed, so CI needs no rsvg):
#   background.png / background@2x.png  Finder window art (800x400, BGDesk layout)
#   volume-icon.icns                     mounted-volume icon (drive + app icon)
# Needs rsvg-convert (brew install librsvg). scripts/make-icon.sh runs it, so
# the drive always carries the current app icon.
set -euo pipefail
cd "$(dirname "$0")/../Resources/dmg"

work="$(mktemp -d)"
trap 'rm -rf "$work" app-icon.png' EXIT

rsvg-convert -w 1024 -h 1024 ../../design/AppIcon.svg -o app-icon.png
rsvg-convert -w 800 -h 400 background.svg -o background.png
rsvg-convert -w 1600 -h 800 background.svg -o background@2x.png

iconset="$work/volume.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -b none -w $size -h $size volume-icon.svg -o "$iconset/icon_${size}x${size}.png"
  rsvg-convert -b none -w $((size * 2)) -h $((size * 2)) volume-icon.svg -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o volume-icon.icns
echo "Resources/dmg: background.png background@2x.png volume-icon.icns"
