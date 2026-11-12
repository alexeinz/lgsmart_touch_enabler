#!/usr/bin/env bash
# Package "LG Smart Touch Enabler.app" into a drag-to-install DMG at ./build/
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="LG Smart Touch Enabler"
APP="build/$NAME.app"

[ -d "$APP" ] || ./scripts/build-app.sh
# The DMG is named after the version stamped into the app by build-app.sh.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/LG-Smart-Touch-Enabler-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Built $DMG"
echo "Note: not notarized; on another Mac use right-click > Open the first time."
