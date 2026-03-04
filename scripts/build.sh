#!/bin/bash
set -euo pipefail

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
DIST="dist"
APP="$DIST/Dictate.app"

# Build (Apple Silicon only)
swift build -c release \
    -Xswiftc -no-whole-module-optimization

# Assemble .app bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$(swift build --show-bin-path -c release)/dictate" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Stamp version into Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

echo "Built $APP (v$VERSION build $BUILD_NUMBER)"
file "$APP/Contents/MacOS/dictate"
