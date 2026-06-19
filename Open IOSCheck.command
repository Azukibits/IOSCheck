#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLED_APP="/Applications/IOSCheck.app"
DMG_APP="$SCRIPT_DIR/IOSCheck.app"

if [[ -d "$INSTALLED_APP" ]]; then
  APP_PATH="$INSTALLED_APP"
else
  APP_PATH="$DMG_APP"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle: $APP_PATH"
  exit 1
fi

xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
open "$APP_PATH"
