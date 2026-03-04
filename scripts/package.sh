#!/bin/bash
set -euo pipefail

APP="dist/Dictate.app"
IDENTITY="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"

# Build + sign
scripts/build.sh
scripts/sign.sh "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/Dictate-${VERSION}.dmg"

# Create DMG
if command -v create-dmg &>/dev/null; then
    create-dmg --overwrite "$APP" dist/ || true
    mv "dist/Dictate ${VERSION}.dmg" "$DMG" 2>/dev/null || true
else
    hdiutil create -volname "Dictate" -srcfolder "$APP" \
        -ov -format UDZO "$DMG"
fi

echo "Created: $DMG"

# Notarize if Developer ID is available
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    echo "Notarizing app..."
    ditto -c -k --keepParent "$APP" /tmp/Dictate.app.zip
    xcrun notarytool submit /tmp/Dictate.app.zip \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm /tmp/Dictate.app.zip

    rm -f "$DMG"
    if command -v create-dmg &>/dev/null; then
        create-dmg --overwrite "$APP" dist/ || true
        mv "dist/Dictate ${VERSION}.dmg" "$DMG" 2>/dev/null || true
    else
        hdiutil create -volname "Dictate" -srcfolder "$APP" \
            -ov -format UDZO "$DMG"
    fi

    codesign -f -s "$IDENTITY" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"

    echo "Notarized: $DMG"
    spctl -a -vvv -t open --context context:primary-signature "$DMG"
else
    echo "Skipped notarization (no DEVELOPER_ID set)"
    echo "To notarize: export DEVELOPER_ID='Developer ID Application: Name (TEAMID)'"
fi
