#!/bin/bash
set -euo pipefail

APP_PLIST="dist/Dictate.app/Contents/Info.plist"
RESOURCES_PLIST="Resources/Info.plist"

# Prefer version from the built app (so package.sh was run with desired VERSION)
if [ -f "$APP_PLIST" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
else
    # Fallback: use Resources/Info.plist or first argument
    VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$RESOURCES_PLIST")}"
    BUILD_NUMBER="${2:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$RESOURCES_PLIST")}"
fi

TAG="v$VERSION"

# Keep Resources/Info.plist in sync
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$RESOURCES_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$RESOURCES_PLIST"

# Commit, tag, push
git add "$RESOURCES_PLIST"
git commit -m "Bump version to $VERSION ($BUILD_NUMBER)"
git tag "$TAG"
git push origin HEAD
git push origin "$TAG"

echo "Tagged and pushed $TAG"
