#!/bin/bash
set -euo pipefail

APP_NAME="Dictate.app"
INSTALL_DIR="/Applications"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/$APP_NAME"

if [ ! -d "$SOURCE_APP" ]; then
    echo "Error: $APP_NAME not found next to this script."
    exit 1
fi

DEST="$INSTALL_DIR/$APP_NAME"

if [ -L "$DEST" ]; then
    echo "Error: $DEST is a symlink, aborting."
    exit 1
elif [ -d "$DEST" ]; then
    echo "Removing existing $DEST..."
    rm -rf "$DEST"
fi

echo "Installing $APP_NAME to $INSTALL_DIR..."
if ! cp -R "$SOURCE_APP" "$INSTALL_DIR/"; then
    echo "Error: Permission denied. Try: sudo $0"
    exit 1
fi

echo "Removing quarantine..."
if xattr "$DEST" 2>/dev/null | grep -q com.apple.quarantine; then
    xattr -dr com.apple.quarantine "$DEST"
fi

echo "Ejecting DMG..."
hdiutil detach "$SCRIPT_DIR" -quiet 2>/dev/null || true

echo "Done. Launch Dictate from /Applications or Spotlight."
