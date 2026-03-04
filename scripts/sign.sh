#!/bin/bash
set -euo pipefail

APP="${1:-dist/Dictate.app}"
ENTITLEMENTS="Resources/Dictate.entitlements"
IDENTITY="${DEVELOPER_ID:--}"  # "-" = ad-hoc signing

echo "Signing with identity: $IDENTITY"

# Main executable
codesign -f -s "$IDENTITY" -o runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    "$APP/Contents/MacOS/dictate"

# App bundle
codesign -f -s "$IDENTITY" -o runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

echo "Signed: $APP"
codesign -dv "$APP" 2>&1 | head -5
