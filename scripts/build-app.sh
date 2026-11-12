#!/usr/bin/env bash
# Build Touchd.app (menu-bar settings app + driver) into ./build/Touchd.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Touchd.app"
IDENTITY="${CODESIGN_IDENTITY:--}"   # "-" = ad-hoc; set CODESIGN_IDENTITY to keep TCC grants across rebuilds

swift build -c release --product TouchdApp
BIN="$(swift build -c release --show-bin-path)/TouchdApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Touchd"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.touchd.app</string>
  <key>CFBundleName</key><string>Touchd</string>
  <key>CFBundleDisplayName</key><string>Touchd</string>
  <key>CFBundleExecutable</key><string>Touchd</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign "$IDENTITY" "$APP"
echo "Built $APP"
echo "Install:  cp -R $APP /Applications/   then open it and grant Accessibility + Input Monitoring."
