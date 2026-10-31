#!/bin/bash
# Regenerate Resources/AppIcon.icns from a palette of scripts/app_icon.py.
# Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/.."
PALETTE="${1:-oceano}"
BACKGROUND="${2:-preto}"

mkdir -p Resources design
python3 -I scripts/app_icon.py "$PALETTE" design/AppIcon.svg "$BACKGROUND"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size design/AppIcon.svg -o "$ICONSET/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) design/AppIcon.svg -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Resources/AppIcon.icns ($PALETTE, $BACKGROUND)"
