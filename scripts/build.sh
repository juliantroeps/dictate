#!/bin/bash
set -euo pipefail

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.1.0")-local}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
DIST="dist"
APP="$DIST/Dictate.app"

# Build (Apple Silicon only). Native build system: swiftbuild (Swift 6.4 default) stamps the
# binary with the deployment target as SDK version (14.0), opting out of macOS 26+ SDK behavior.
BUILD=(-c release --build-system native)
swift build "${BUILD[@]}" --product dictate
BIN="$(swift build "${BUILD[@]}" --show-bin-path)/dictate"

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
otool -l "$APP/Contents/MacOS/dictate" | grep -A4 LC_BUILD_VERSION | grep -E "minos|sdk"
