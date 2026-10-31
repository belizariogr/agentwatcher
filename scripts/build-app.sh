#!/bin/bash
# Build AgentWatcher.app (menu bar only, no Dock icon) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

# Version from the nearest vX.Y.Z tag; build number from the commit count.
VERSION="${VERSION:-$( (git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true) | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/AgentWatcher.app"

# UNIVERSAL=1 builds one binary for Apple silicon and Intel (used for releases).
ARCH_ARGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_ARGS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/AgentWatcher"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentWatcher"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIdentifier</key><string>com.belizariogr.agentwatcher</string>
  <key>CFBundleName</key><string>AgentWatcher</string>
  <key>CFBundleDisplayName</key><string>Agent Watcher</string>
  <key>CFBundleExecutable</key><string>AgentWatcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature for local runs; scripts/release.sh re-signs with Developer ID.
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
