#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/IOSCheck.app"
TARGET_APP="/Applications/IOSCheck.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  osascript -e 'display alert "IOSCheck.app not found in this disk image."'
  exit 1
fi

rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" /Applications/
xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
open "$TARGET_APP"
