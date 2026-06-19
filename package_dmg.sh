#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/IOSCheck.app"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/IOSCheck-macOS.dmg"
CMAKE_BIN="/Applications/CLion.app/Contents/bin/cmake/mac/aarch64/bin/cmake"

if [[ ! -x "$CMAKE_BIN" ]]; then
  echo "Missing cmake: $CMAKE_BIN" >&2
  exit 1
fi

"$CMAKE_BIN" -S "$ROOT_DIR" -B "$BUILD_DIR"
"$CMAKE_BIN" --build "$BUILD_DIR"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

hdiutil create \
  -volname "IOSCheck" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Created: $DMG_PATH"
