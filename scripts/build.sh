#!/bin/bash
set -euo pipefail

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.1.0")-local}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
DIST="dist"
APP="$DIST/Dictate.app"

# Build (Apple Silicon only)
swift build -c release --product dictate
BIN="$(swift build -c release --show-bin-path)/dictate"

# Assemble .app bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Extract dSYM for Sentry symbolication (kept out of the .app / DMG)
dsymutil "$BIN" -o "$DIST/dictate.dSYM"

# Stamp version into Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

echo "Built $APP (v$VERSION build $BUILD_NUMBER)"
file "$APP/Contents/MacOS/dictate"
