#!/bin/bash
# Builds build/Murmur.app.
#   scripts/build-app.sh             release build, ad-hoc signed
#   scripts/build-app.sh --install   also copy to /Applications and launch
# Set SIGN_ID to a code-signing identity (e.g. a self-signed "Murmur Local")
# so macOS keeps Accessibility/Microphone grants across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SIGN_ID="${SIGN_ID:--}"
APP="build/Murmur.app"

swift build -c "$CONFIG" --product Murmur
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Murmur" "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$SIGN_ID" --identifier dev.murmur.app "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $SIGN_ID)"

if [ "${1:-}" = "--install" ]; then
  pkill -x Murmur 2>/dev/null || true
  rm -rf /Applications/Murmur.app
  cp -R "$APP" /Applications/Murmur.app
  open /Applications/Murmur.app
  echo "Installed /Applications/Murmur.app"
fi
