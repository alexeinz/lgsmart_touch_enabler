#!/usr/bin/env bash
# Package "LG Smart Touch Enabler.app" into a drag-to-install DMG at ./build/
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="LG Smart Touch Enabler"
APP="build/$NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 2.0.0)"
DMG="build/LG-Smart-Touch-Enabler-$VERSION.dmg"

[ -d "$APP" ] || ./scripts/build-app.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Built $DMG"
echo "Note: ad-hoc signed and not notarized; on another Mac use right-click > Open the first time."
