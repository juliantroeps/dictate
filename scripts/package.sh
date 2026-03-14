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

# Stage DMG contents (app + installer)
STAGING="dist/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
cp "$(dirname "$0")/install.sh" "$STAGING/"
chmod +x "$STAGING/install.sh"

# Create DMG
if command -v create-dmg &>/dev/null; then
    if ! create-dmg --overwrite "$STAGING" dist/; then
        echo "create-dmg failed, falling back to hdiutil"
        hdiutil create -volname "Dictate" -srcfolder "$STAGING" \
            -ov -format UDZO "$DMG"
    else
        mv "dist/Dictate ${VERSION}.dmg" "$DMG" 2>/dev/null || true
    fi
else
    hdiutil create -volname "Dictate" -srcfolder "$STAGING" \
        -ov -format UDZO "$DMG"
fi

if [ ! -f "$DMG" ]; then
    echo "Error: DMG not created at $DMG"
    exit 1
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
    rm -rf "$STAGING/Dictate.app"
    cp -R "$APP" "$STAGING/"  # refresh staged app after stapling
    if command -v create-dmg &>/dev/null; then
        if ! create-dmg --overwrite "$STAGING" dist/; then
            echo "create-dmg failed, falling back to hdiutil"
            hdiutil create -volname "Dictate" -srcfolder "$STAGING" \
                -ov -format UDZO "$DMG"
        else
            mv "dist/Dictate ${VERSION}.dmg" "$DMG" 2>/dev/null || true
        fi
    else
        hdiutil create -volname "Dictate" -srcfolder "$STAGING" \
            -ov -format UDZO "$DMG"
    fi

    if [ ! -f "$DMG" ]; then
        echo "Error: DMG not created at $DMG"
        exit 1
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

rm -rf "$STAGING"
