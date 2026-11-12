import Foundation
import TouchCore

let usage = """
touchd — userspace multi-touch driver for the LG MFTouch monitor

USAGE: touchd [command]

  run (default)   Start the driver in the foreground (Ctrl-C to quit)
  status          Show permissions, display and configuration summary
  dump            Print raw HID values from the touchscreen (for debugging)
  config path     Print the config file location
  config print    Print the effective configuration as JSON
  config reset    Delete the config file (defaults are used again)
  help            Show this text

The menu-bar app (TouchdApp) edits the same config file; the daemon reloads it live.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1)
}

func ts() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
}

let store = ConfigStore()
let args = Array(CommandLine.arguments.dropFirst())

switch args.first ?? "run" {
case "help", "-h", "--help":
    print(usage)

case "config":
    switch args.dropFirst().first {
    case "path": print(store.url.path)
    case "print":
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try enc.encode(store.load()), as: UTF8.self))
    case "reset":
        try? FileManager.default.removeItem(at: store.url); print("Config reset.")
    default: fail(usage)
    }

case "status":
    let cfg = store.load()
    print("Config file:        \(store.url.path) (\(store.exists ? "present" : "defaults"))")
    print("Accessibility:      \(Permissions.accessibilityGranted ? "granted" : "MISSING")")
    print("Input Monitoring:   \(Permissions.inputMonitoringGranted ? "granted" : "MISSING")")
    for d in Displays.all() {
        let mark = d.id == Displays.target(preferred: cfg.displayID) ? "→" : " "
        print("\(mark) display \(d.id): \(d.name)\(d.isBuiltin ? " (built-in)" : "") \(Int(d.bounds.width))x\(Int(d.bounds.height))")
    }
    print("Rotation:           \(cfg.rotation)°  Scroll speed: \(cfg.scrollSpeed)x  Gestures: \(cfg.gesturesEnabled ? "on" : "off")")

case "dump":
    let cfg = store.load()
    let src = HIDTouchSource()
    src.onRawValue = { page, usage, value, parent in
        print(String(format: "%@ page=0x%02X usage=0x%02X value=%d parent=%x", ts(), page, usage, value, parent & 0xFFFF))
    }
    guard src.start(vendorID: cfg.vendorID, productID: cfg.productID) else {
        fail("Could not open HID device. Grant Input Monitoring to your terminal.")
    }
    signal(SIGINT, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sig.setEventHandler { exit(0) }; sig.resume()
    print("Dumping raw HID values; Ctrl-C to stop.")
    CFRunLoopRun()

case "run":
    if !Permissions.accessibilityGranted {
        Permissions.requestAccessibility()
        print("⚠️  Accessibility permission needed (System Settings → Privacy & Security → Accessibility).")
    }
    let service = TouchService(config: store.load())
    service.log = { print("\(ts()) \($0)") }
    var lastStatus = ServiceStatus()
    service.onStatus = { s in
        if s.deviceConnected != lastStatus.deviceConnected {
            print("\(ts()) touchscreen \(s.deviceConnected ? "connected" : "disconnected")")
        }
        lastStatus = s
    }
    guard service.start() || !service.config.enabled else {
        fail("Could not open HID device. Grant Input Monitoring to your terminal / this binary.")
    }
    print("touchd running on \"\(service.status.displayName)\". Ctrl-C to quit.")

    // Live-reload the config file when the app edits it.
    var lastMod = store.modificationDate
    let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        service.refreshStatus()
        let m = store.modificationDate
        if m != lastMod { lastMod = m; service.update(config: store.load()); print("\(ts()) config reloaded") }
    }
    _ = timer

    for s in [SIGINT, SIGTERM] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
        src.setEventHandler { service.stop(); exit(0) }
        src.resume()
        signalSources.append(src)
    }
    CFRunLoopRun()

default:
    fail(usage)
}

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
