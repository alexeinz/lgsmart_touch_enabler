#!/usr/bin/env bash
# Install the headless `touchd` CLI as a per-user LaunchAgent (alternative to the menu-bar app).
# Usage: scripts/install-launchagent.sh [install|uninstall]
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.touchd.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DEST="$HOME/.local/bin/touchd"

case "${1:-install}" in
  install)
    swift build -c release --product touchd
    mkdir -p "$(dirname "$DEST")" "$(dirname "$PLIST")"
    cp "$(swift build -c release --show-bin-path)/touchd" "$DEST"
    codesign --force --sign - "$DEST"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/touchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/touchd.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Installed. Grant Accessibility + Input Monitoring to $DEST in System Settings, then:"
    echo "  launchctl kickstart -k gui/$(id -u)/$LABEL"
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$DEST"
    echo "Uninstalled."
    ;;
  *) echo "usage: $0 [install|uninstall]"; exit 1 ;;
esac
