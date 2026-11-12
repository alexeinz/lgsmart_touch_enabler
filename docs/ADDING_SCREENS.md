# Adding another touch screen

The app is not LG-specific. It reads any USB/Bluetooth HID **digitizer** that reports, per contact, *Tip Switch* (usage page 0x0D, usage 0x42), *X* (0x01/0x30) and *Y* (0x01/0x31), and optionally *Contact Count* (0x0D/0x54). Most touch monitors do. Coordinates are normalized using each element's own logical min/max, so resolution does not matter.

Parsing lives in `Sources/TouchCore/HIDTouchSource.swift`. The match is only `VendorID` + `ProductID`.

## 1. Find the VID/PID

With the screen plugged in:

```bash
ioreg -p IOUSB -l -w0 | grep -iE '"(idVendor|idProduct|USB Product Name)"'
# or: System Information → USB
```

Convert the decimal values to hex (`printf '0x%04X\n' 43083`). The LG is `0x284B / 0x8300`.

## 2. Check that the device speaks the expected protocol

Edit the config (`touchd config path`) and set `vendorID` / `productID` (decimal in JSON), or edit the defaults in `Sources/TouchCore/Config.swift`. Then:

```bash
swift build && .build/debug/touchd dump
```

Touch the screen. You should see lines for page `0x0D` usage `0x42` (tip), page `0x01` usages `0x30`/`0x31` (X/Y), and a distinct parent per finger. Grant Input Monitoring to your terminal first if nothing prints.

| What you see | Meaning / action |
|---|---|
| No output at all | Wrong VID/PID, missing Input Monitoring, or the screen is being claimed by another driver. Run `touchd status`. |
| Tip + X + Y per finger | Supported as is. Continue to step 3. |
| X/Y but no Tip Switch (page 0x0D/0x42) | Some devices use *In Range* (0x0D/0x32) or *Confidence* (0x0D/0x47). Add that usage to the `switch` in `HIDTouchSource.handle`. |
| Absolute X/Y on page 0x01 but no contact IDs/parents | Single-touch only; works, multi-finger gestures will not. |
| Relative X/Y (mouse-like) | It is a pointer, not a digitizer; the OS already handles it. |
| Several HID interfaces for one VID/PID | Fine; fingers are keyed per HID collection. If other interfaces add noise, filter on `kIOHIDPrimaryUsagePageKey` in the matching dictionary. |

## 3. Map it to the right display

Open **Settings → General** and pick the display the touch panel belongs to, then set **rotation** (0/90/180/270) until a touch lands under your finger. The **Test** tab shows live contacts. Multiple monitors: choose the panel's display, not "Main".

Headless: set `displayID` (from `touchd status`) and `rotation` in the config.

## 4. Tune

Different panels differ in size and noise. In **Settings → Sensitivity** adjust move threshold, tap/hold times, scroll speed and swipe distance. `touchd config print` shows every value.

## 5. Verify

- Tap, drag, hold (right-click), two-finger scroll, two-finger tap.
- Swipes with 3+ fingers, only if the panel reports at least that many contacts (watch the Test tab).
- Run `./scripts/test.sh`; the engine tests are hardware independent.

## 6. Contribute it

If the screen works, open a PR or issue with:

- VID/PID, product name, panel size and max contact count
- a short `touchd dump` capture (a few lines of one tap)
- any code change from step 2 and the sensitivity values that felt right

## Supporting several screens at once (future work)

Today there is a single `vendorID`/`productID` pair and one target display. To support two panels at once:

1. Turn the config pair into a list of `{vendorID, productID, displayID, rotation}` entries.
2. Start one `HIDTouchSource` per entry in `TouchService`, each with its own `GestureEngine`.
3. Key the General tab's display and rotation pickers per device.

## Monitor tab caveat

Input switching and volume use DDC/CI and are separate from touch. They depend on the monitor and the Mac port, not on the VID/PID; see the README.
