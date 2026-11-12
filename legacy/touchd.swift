// touchd v2 — userspace multi-touch driver for macOS (HID digitizer -> mouse/scroll/key events)
// Build: swiftc -O touchd.swift -o touchd
// Usage: ./touchd [--list] [--dump] [--display <id>] [--rotate 0|90|180|270]
//                 [--scroll <speed>] [--no-gestures] [--vid 0x284B] [--pid 0x8300] [-v]
//
// Gestures:
//   1 finger  : tap=click, double-tap=double-click, drag, hold 0.6s=right-click
//   2 fingers : drag=scroll, pinch=zoom (Cmd +/Cmd -)
//   3+ fingers: swipe left/right = Ctrl+Right/Left (switch Space), up = Ctrl+Up (Mission Control),
//               down = Ctrl+Down (App Exposé)
//   4-5 fingers: pinch in = F4 (Launchpad), spread out = F11 (Show Desktop)

import Foundation
import IOKit.hid
import ApplicationServices

// ---------- config ----------
var VID = 0x284B
var PID = 0x8300
var rotate = 0
var verbose = false
var dumpMode = false
var listMode = false
var gesturesOn = true
var scrollSpeed: CGFloat = 1.0
var displayArg: UInt32? = nil

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--list": listMode = true
    case "--dump": dumpMode = true
    case "-v": verbose = true
    case "--no-gestures": gesturesOn = false
    case "--scroll": if !args.isEmpty { scrollSpeed = CGFloat(Double(args.removeFirst()) ?? 1.0) }
    case "--display": if !args.isEmpty { displayArg = UInt32(args.removeFirst()) }
    case "--rotate": if !args.isEmpty { rotate = Int(args.removeFirst()) ?? 0 }
    case "--vid": if !args.isEmpty { VID = Int(args.removeFirst().dropFirst(2), radix: 16) ?? VID }
    case "--pid": if !args.isEmpty { PID = Int(args.removeFirst().dropFirst(2), radix: 16) ?? PID }
    default: print("unknown arg \(a)"); exit(2)
    }
}

// ---------- displays ----------
func activeDisplays() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    return ids
}

if listMode {
    for d in activeDisplays() {
        let b = CGDisplayBounds(d)
        print("display id=\(d) builtin=\(CGDisplayIsBuiltin(d) != 0) main=\(CGDisplayIsMain(d) != 0) bounds=\(b)")
    }
    exit(0)
}

func targetDisplay() -> CGDirectDisplayID {
    let all = activeDisplays()
    if let id = displayArg, all.contains(id) { return id }
    return all.first(where: { CGDisplayIsBuiltin($0) == 0 }) ?? CGMainDisplayID()
}

// ---------- state ----------
struct Finger { var tip = false; var x = 0.0; var y = 0.0 }  // x,y normalized 0...1
var fingers: [Int: Finger] = [:]      // keyed by the HID collection (one per finger slot)
var processScheduled = false
var contactCount = 0

enum Mode { case idle, pending, dragging, two, multi, consumed }
enum TwoMode { case undecided, scroll, pinch }
var mode = Mode.idle
var twoMode = TwoMode.undecided
var startPt = CGPoint.zero
var lastPt = CGPoint.zero
var baseC = CGPoint.zero      // gesture baseline centroid
var baseS: CGFloat = 0        // gesture baseline spread
var refS: CGFloat = 0         // pinch reference spread (zoom steps)
var lastC = CGPoint.zero      // last centroid for scroll
var multiN = 0
var fired = false
var lastTapTime = Date.distantPast
var lastTapPt = CGPoint.zero
var longPress: DispatchWorkItem? = nil

let moveThreshold: CGFloat = 8
let longPressDelay = 0.6
let doubleTapWindow = 0.4

// ---------- event posting ----------
let src = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
}

func scroll(dx: CGFloat, dy: CGFloat) {
    guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                          wheel1: Int32((dy * scrollSpeed).rounded()),
                          wheel2: Int32((dx * scrollSpeed).rounded()), wheel3: 0) else { return }
    e.post(tap: .cghidEventTap)
}

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}

let kLeft: CGKeyCode = 123, kRight: CGKeyCode = 124, kDown: CGKeyCode = 125, kUp: CGKeyCode = 126
let kEqual: CGKeyCode = 24, kMinus: CGKeyCode = 27, kF4: CGKeyCode = 118, kF11: CGKeyCode = 103
let ctrlFn: CGEventFlags = [.maskControl, .maskSecondaryFn]

func log(_ s: String) { if verbose { print(s) } }

// ---------- geometry ----------
func toScreen(_ f: Finger) -> CGPoint {
    var nx = f.x, ny = f.y
    switch rotate {
    case 90:  (nx, ny) = (1 - f.y, f.x)
    case 180: (nx, ny) = (1 - f.x, 1 - f.y)
    case 270: (nx, ny) = (f.y, 1 - f.x)
    default: break
    }
    let b = CGDisplayBounds(targetDisplay())
    return CGPoint(x: b.origin.x + nx * b.width, y: b.origin.y + ny * b.height)
}

func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

func centroid(_ pts: [CGPoint]) -> CGPoint {
    CGPoint(x: pts.map { $0.x }.reduce(0, +) / CGFloat(pts.count),
            y: pts.map { $0.y }.reduce(0, +) / CGFloat(pts.count))
}

func spread(_ pts: [CGPoint], _ c: CGPoint) -> CGFloat {
    pts.map { dist($0, c) }.reduce(0, +) / CGFloat(pts.count)
}

func cancelLongPress() { longPress?.cancel(); longPress = nil }

// ---------- gesture state machine ----------
func beginPending(_ p: CGPoint) {
    startPt = p; lastPt = p
    mode = .pending
    let work = DispatchWorkItem {
        guard mode == .pending else { return }
        log("right-click")
        post(.rightMouseDown, startPt, button: .right)
        post(.rightMouseUp, startPt, button: .right)
        mode = .consumed
    }
    longPress = work
    DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
}

func beginTwo(_ c: CGPoint, _ s: CGFloat) {
    cancelLongPress()
    mode = .two; twoMode = .undecided
    baseC = c; baseS = s; refS = s; lastC = c
}

func beginMulti(_ n: Int, _ c: CGPoint, _ s: CGFloat) {
    cancelLongPress()
    if mode != .multi { fired = false }
    mode = .multi
    multiN = n; baseC = c; baseS = s
}

func handleTwo(_ c: CGPoint, _ s: CGFloat, _ W: CGFloat) {
    switch twoMode {
    case .undecided:
        let dc = dist(c, baseC), ds = abs(s - baseS)
        if gesturesOn && ds > 0.010 * W && ds > dc {
            twoMode = .pinch; refS = s
        } else if dc > 0.006 * W {
            twoMode = .scroll; lastC = baseC
            scroll(dx: c.x - lastC.x, dy: c.y - lastC.y); lastC = c
        }
    case .scroll:
        scroll(dx: c.x - lastC.x, dy: c.y - lastC.y); lastC = c
    case .pinch:
        let r = s / max(refS, 1)
        if r > 1.15 { log("zoom in");  key(kEqual, .maskCommand); refS = s }
        else if r < 0.87 { log("zoom out"); key(kMinus, .maskCommand); refS = s }
    }
}

func handleMulti(_ c: CGPoint, _ s: CGFloat, _ W: CGFloat) {
    guard gesturesOn, !fired, multiN <= 5 else { return }
    let dx = c.x - baseC.x, dy = c.y - baseC.y
    if max(abs(dx), abs(dy)) > 0.06 * W {
        fired = true
        if abs(dx) > abs(dy) {
            log("swipe \(dx < 0 ? "left -> next Space" : "right -> previous Space")")
            key(dx < 0 ? kRight : kLeft, ctrlFn)
        } else if dy < 0 {
            log("swipe up -> Mission Control"); key(kUp, ctrlFn)
        } else {
            log("swipe down -> App Expose"); key(kDown, ctrlFn)
        }
    } else if multiN >= 4 {
        let r = s / max(baseS, 1)
        if r < 0.7 { fired = true; log("pinch in -> Launchpad"); key(kF4) }
        else if r > 1.4 { fired = true; log("spread -> Show Desktop"); key(kF11) }
    }
}

func finish() {
    cancelLongPress()
    if mode == .pending {
        var clicks: Int64 = 1
        if Date().timeIntervalSince(lastTapTime) < doubleTapWindow && dist(lastTapPt, startPt) < 30 { clicks = 2 }
        log("tap x\(clicks)")
        post(.mouseMoved, startPt)
        post(.leftMouseDown, startPt, clicks: clicks)
        post(.leftMouseUp, startPt, clicks: clicks)
        lastTapTime = clicks == 2 ? .distantPast : Date()
        lastTapPt = startPt
    } else if mode == .dragging {
        post(.leftMouseUp, lastPt)
    }
    mode = .idle; fired = false; multiN = 0
}

func process() {
    processScheduled = false
    let pts = fingers.values.filter { $0.tip }.map(toScreen)
    let n = pts.count
    log("fingers=\(n) count=\(contactCount) mode=\(mode)")
    if n == 0 { finish(); return }

    let W = CGDisplayBounds(targetDisplay()).width
    let c = centroid(pts)
    let s = spread(pts, c)

    switch mode {
    case .idle:
        if n == 1 { beginPending(pts[0]) }
        else if n == 2 { beginTwo(c, s) }
        else { beginMulti(n, c, s) }

    case .pending:
        if n == 1 {
            if dist(pts[0], startPt) > moveThreshold {
                cancelLongPress()
                post(.leftMouseDown, startPt)
                post(.leftMouseDragged, pts[0])
                lastPt = pts[0]
                mode = .dragging
            }
        } else if n == 2 { beginTwo(c, s) }
        else { beginMulti(n, c, s) }

    case .dragging:
        if n == 1 { post(.leftMouseDragged, pts[0]); lastPt = pts[0] }

    case .two:
        if n == 2 { handleTwo(c, s, W) }
        else if n >= 3 { beginMulti(n, c, s) }
        else { mode = .consumed }

    case .multi:
        if n == multiN { handleMulti(c, s, W) }
        else if n >= 3 { multiN = n; baseC = c; baseS = s }   // finger count changed: re-baseline
        else { mode = .consumed }

    case .consumed:
        break
    }
}

// ---------- HID input ----------
let valueCallback: IOHIDValueCallback = { _, _, _, value in
    let el = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(el)
    let usage = IOHIDElementGetUsage(el)
    let v = Double(IOHIDValueGetIntegerValue(value))
    let parent: IOHIDElement? = IOHIDElementGetParent(el)
    let key = parent.map { Int(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0

    if dumpMode { print(String(format: "page=0x%02X usage=0x%02X value=%.0f key=%x", page, usage, v, key)) }

    func schedule() {
        if !processScheduled && !dumpMode {
            processScheduled = true
            DispatchQueue.main.async { process() }
        }
    }

    if page == 0x0D && usage == 0x54 {            // Contact Count
        contactCount = Int(v)
        if contactCount == 0 { for k in fingers.keys { fingers[k]?.tip = false } }
        schedule()
        return
    }

    var f = fingers[key] ?? Finger()
    let lo = Double(IOHIDElementGetLogicalMin(el)), hi = Double(IOHIDElementGetLogicalMax(el))
    let norm = hi > lo ? min(max((v - lo) / (hi - lo), 0), 1) : 0

    switch (page, usage) {
    case (0x0D, 0x42): f.tip = v != 0
    case (0x01, 0x30): f.x = norm
    case (0x01, 0x31): f.y = norm
    default: return
    }
    fingers[key] = f
    schedule()
}

let attachCallback: IOHIDDeviceCallback = { _, _, _, dev in
    let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
    print("touch device attached: \(name)")
    if dumpMode, let els = IOHIDDeviceCopyMatchingElements(dev, nil, 0) as? [IOHIDElement] {
        for e in els {
            print(String(format: "element page=0x%02X usage=0x%02X min=%d max=%d type=%d",
                         IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e),
                         IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e), IOHIDElementGetType(e).rawValue))
        }
    }
}

// ---------- main ----------
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(opts) && !dumpMode {
    print("Accessibility permission needed: System Settings > Privacy & Security > Accessibility — enable your Terminal, then re-run.")
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(mgr, attachCallback, nil)
IOHIDManagerRegisterInputValueCallback(mgr, valueCallback, nil)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
if r != kIOReturnSuccess {
    print(String(format: "IOHIDManagerOpen failed 0x%08x — grant Input Monitoring to your Terminal (System Settings > Privacy & Security > Input Monitoring), then re-run.", r))
    exit(1)
}
let d = targetDisplay()
print("touchd v2 running. target display id=\(d) bounds=\(CGDisplayBounds(d)) rotate=\(rotate) gestures=\(gesturesOn). Ctrl-C to quit.")
CFRunLoopRun()
