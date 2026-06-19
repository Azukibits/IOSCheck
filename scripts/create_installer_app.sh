#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Install IOSCheck.app"
APP_DIR="$DIST_DIR/$APP_NAME"
APPLESCRIPT_PATH="$DIST_DIR/install_ioscheck.applescript"

rm -rf "$APP_DIR"

cat > "$APPLESCRIPT_PATH" <<'EOF'
on run
    set installCommand to "SOURCE_APP=\"$(find /Volumes -maxdepth 2 -type d -path '/Volumes/IOSCheck*/IOSCheck.app' | tail -n 1)\"; " & ¬
        "if [ -z \"$SOURCE_APP\" ]; then echo 'IOSCheck.app not found in mounted volume.'; exit 1; fi; " & ¬
        "cp -R \"$SOURCE_APP\" /Applications/ && " & ¬
        "xattr -dr com.apple.quarantine /Applications/IOSCheck.app && " & ¬
        "open /Applications/IOSCheck.app"
    tell application "Terminal"
        activate
        do script installCommand
    end tell
end run
EOF

osacompile -o "$APP_DIR" "$APPLESCRIPT_PATH"
rm -f "$APPLESCRIPT_PATH"

echo "Created: $APP_DIR"
