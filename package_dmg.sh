#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/IOSCheck.app"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/IOSCheck-macOS.dmg"
STAGING_DIR="$DIST_DIR/dmg-staging"
HELPER_SCRIPT="$ROOT_DIR/Open IOSCheck.command"
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
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -R "$APP_PATH" "$STAGING_DIR/"
cp "$HELPER_SCRIPT" "$STAGING_DIR/"
chmod +x "$STAGING_DIR/Open IOSCheck.command"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "IOSCheck" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "Created: $DMG_PATH"
