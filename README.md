# touchd

A userspace touch driver for macOS. It makes the touchscreen on the **LG 31.5" 4K Smart Monitor Swing** (MFTouch HID digitizer, `VID 0x284B / PID 0x8300`) work as a real touch input, which macOS does not support natively. It ships a menu-bar settings app and a headless daemon.

- Tap = click, drag = drag, hold = right-click, double-tap = double-click
- Two-finger drag = scroll, two-finger pinch = zoom
- 3/4/5-finger swipes and 4-finger pinch fire **configurable keyboard shortcuts**
- Up to 10 simultaneous contacts are tracked
- Settings app: shortcuts, sensitivity, display and rotation, launch at login
- Config is one JSON file, live-reloaded by the daemon

> **Status:** single-touch and two-finger scroll are confirmed on hardware. Multi-finger gestures (pinch, 3/4/5-finger swipes) are covered by unit tests but **not yet verified on the real monitor**. Expect to tweak sensitivity.

## Requirements

- macOS 13 or later (developed on macOS 27, Apple silicon)
- Swift 5.9+ toolchain (Command Line Tools are enough; Xcode is not required)

## Install

### Option A: menu-bar app (recommended)

```bash
./scripts/build-app.sh
cp -R build/Touchd.app /Applications/
open /Applications/Touchd.app
```

Open **Settings…** from the menu-bar icon, then:

1. **Permissions** tab: grant **Accessibility** and **Input Monitoring**.
2. **General** tab: turn on **Launch at login**.

The app is ad-hoc signed by default, and macOS ties permissions to the signature. If you rebuild, the grants may reset. To keep them, sign with a stable identity:

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./scripts/build-app.sh
```

### Option B: headless daemon

```bash
./scripts/install-launchagent.sh install     # installs ~/.local/bin/touchd + LaunchAgent com.touchd.daemon
./scripts/install-launchagent.sh uninstall
```

Grant Accessibility and Input Monitoring to `~/.local/bin/touchd` in System Settings → Privacy & Security.

Run only one of the app or the daemon at a time, since both would inject events.

## Default gestures

| Gesture | Default action |
|---|---|
| 1 finger tap / drag / hold | click / drag / right-click |
| 2 fingers drag | scroll (natural direction, invertible) |
| 2 fingers pinch in / out | ⌘− / ⌘= (zoom) |
| 3, 4 or 5 fingers swipe left / right | ⌃→ / ⌃← (next / previous Space) |
| 3, 4 or 5 fingers swipe up | ⌃↑ (Mission Control) |
| 3, 4 or 5 fingers swipe down | ⌃↓ (App Exposé) |
| 4 fingers pinch in / out | F4 / F11 (Launchpad / Show Desktop) |

Every binding can be re-recorded, chosen from presets, or disabled in **Settings → Gestures**.

**Mission Control caveat:** the Space and Mission Control defaults are the standard macOS shortcuts. Enable them in System Settings → Keyboard → Keyboard Shortcuts → Mission Control, or the gestures will do nothing.

## CLI

```bash
touchd run             # run the daemon in the foreground
touchd status          # permissions, device, display
touchd dump            # print raw HID reports (debugging)
touchd config path     # location of the config file
touchd config print
touchd config reset
```

## Configuration

`~/Library/Application Support/touchd/config.json`, written by the app and watched by the daemon (about 1 s poll). A corrupt file is moved to `config.json.bad` and defaults are used. Missing keys fall back to defaults, so hand-editing is safe.

## Layout

```
Sources/TouchCore/    gesture engine, config, HID source, CG event output (library, unit-tested)
Sources/touchd/       CLI daemon
Sources/TouchdApp/    SwiftUI menu-bar settings app
Tests/TouchCoreTests/ Swift Testing suite (30 tests)
scripts/              build-app.sh, install-launchagent.sh, test.sh
legacy/               original single-file prototypes, kept for reference
```

The engine talks to the OS only through the `EventSink` protocol and injected clock/scheduler, so gesture logic is tested without hardware or permissions.

## Development

```bash
swift build
./scripts/test.sh    # adds the Swift Testing search paths needed with Command Line Tools only
```

## Troubleshooting

- **Nothing happens on touch:** run `touchd status` or check the Permissions tab. Both Accessibility and Input Monitoring are required.
- **After a rebuild permissions stopped working:** remove the app from both lists in System Settings and add it again, or sign with a stable identity.
- **Touch lands on the wrong display or is rotated:** pick the display and rotation in Settings → General.
- **Swipes do nothing:** see the Mission Control caveat above.
- **Different monitor:** the VID/PID are in `Sources/TouchCore/Config.swift`. Use `touchd dump` to inspect your device.

## License

MIT
