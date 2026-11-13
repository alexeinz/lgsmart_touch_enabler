import CoreGraphics
import Foundation

/// Every gesture that can be bound to a shortcut.
public enum GestureID: String, CaseIterable, Sendable {
    case pinch2In, pinch2Out
    case swipe2Left, swipe2Right, smartZoom, tap3, edge2Right, keyboard   // two-finger flick (opt-in) and two-finger double-tap (opt-in)
    case swipe3Left, swipe3Right, swipe3Up, swipe3Down
    case swipe4Left, swipe4Right, swipe4Up, swipe4Down
    case pinch4In, pinch4Out
    case swipe5Left, swipe5Right, swipe5Up, swipe5Down
    case edgeLeft, edgeRight, edgeTop, edgeBottom   // one finger starting at a screen edge, swiping inward

    public static let swipeIDs: [Int: [GestureID]] = [
        3: [.swipe3Left, .swipe3Right, .swipe3Up, .swipe3Down],
        4: [.swipe4Left, .swipe4Right, .swipe4Up, .swipe4Down],
        5: [.swipe5Left, .swipe5Right, .swipe5Up, .swipe5Down],
    ]

    /// Number of fingers this gesture is grouped under in the UI.
    public var fingers: Int {
        switch self {
        case .edgeLeft, .edgeRight, .edgeTop, .edgeBottom: return 1
        case .pinch2In, .pinch2Out, .swipe2Left, .swipe2Right, .smartZoom, .edge2Right, .keyboard: return 2
        case .tap3: return 3
        case .swipe3Left, .swipe3Right, .swipe3Up, .swipe3Down: return 3
        case .swipe4Left, .swipe4Right, .swipe4Up, .swipe4Down, .pinch4In, .pinch4Out: return 4
        case .swipe5Left, .swipe5Right, .swipe5Up, .swipe5Down: return 5
        }
    }

    public var title: String {
        switch self {
        case .edgeLeft: return "From left edge"
        case .edgeRight: return "From right edge"
        case .edgeTop: return "From top edge"
        case .edgeBottom: return "From bottom edge"
        case .tap3: return "Tap (Look Up)"
        case .edge2Right: return "From right edge (Notification Center)"
        case .keyboard: return "Hold still (on-screen keyboard)"
        case .swipe2Left: return "Flick left"
        case .swipe2Right: return "Flick right"
        case .smartZoom: return "Double-tap (smart zoom)"
        case .pinch2In: return "Pinch in"
        case .pinch2Out: return "Spread out"
        case .pinch4In: return "Pinch in (4–5 fingers)"
        case .pinch4Out: return "Spread out (4–5 fingers)"
        case .swipe3Left, .swipe4Left, .swipe5Left: return "Swipe left"
        case .swipe3Right, .swipe4Right, .swipe5Right: return "Swipe right"
        case .swipe3Up, .swipe4Up, .swipe5Up: return "Swipe up"
        case .swipe3Down, .swipe4Down, .swipe5Down: return "Swipe down"
        }
    }

    public var defaultShortcut: Shortcut {
        let cf = Shortcut.ctrlFn
        switch self {
        case .edgeLeft, .edgeRight, .edgeTop, .edgeBottom: return .disabled   // opt-in
        case .swipe2Left, .swipe2Right, .smartZoom, .edge2Right, .keyboard: return .disabled   // opt-in
        case .tap3: return Shortcut(keyCode: 2, flags: [.maskControl, .maskCommand])   // ⌃⌘D: Look Up
        case .pinch2In: return Shortcut(keyCode: Shortcut.kMinus, flags: .maskCommand)
        case .pinch2Out: return Shortcut(keyCode: Shortcut.kEqual, flags: .maskCommand)
        case .pinch4In: return Shortcut(keyCode: Shortcut.kF4)
        case .pinch4Out: return Shortcut(keyCode: Shortcut.kF11)
        // Fingers moving left = go to the next Space (content follows the fingers).
        case .swipe3Left, .swipe4Left, .swipe5Left: return Shortcut(keyCode: Shortcut.kRight, flags: cf)
        case .swipe3Right, .swipe4Right, .swipe5Right: return Shortcut(keyCode: Shortcut.kLeft, flags: cf)
        case .swipe3Up, .swipe4Up, .swipe5Up: return Shortcut(keyCode: Shortcut.kUp, flags: cf)
        case .swipe3Down, .swipe4Down, .swipe5Down: return Shortcut(keyCode: Shortcut.kDown, flags: cf)
        }
    }
}

/// User-tunable settings, persisted as JSON (see `ConfigStore`).
public struct TouchConfig: Codable, Equatable, Sendable {
    // General
    public var enabled = true
    public var gesturesEnabled = true
    public var displayID: UInt32? = nil        // nil = first non-built-in display
    public var rotation = 0                    // 0 / 90 / 180 / 270

    // Sensitivity
    public var scrollSpeed = 1.0               // multiplier
    public var invertScroll = false
    public var momentumScroll = true           // keep scrolling briefly after a flick
    public var twoFingerTapRightClick = true   // quick two-finger tap = right-click
    public var moveThreshold = 8.0             // points before a touch becomes a drag
    public var rightClickOnHold = true
    public var longPressDelay = 0.6            // seconds
    public var doubleTapWindow = 0.4           // seconds
    public var swipeDistance = 0.06            // fraction of display width
    public var zoomStep = 1.15                 // finger-spread ratio per zoom keypress
    public var edgeWidth = 0.015               // edge-swipe start zone, fraction of display width

    // Touch helpers
    public var windowEdgeGrab = false          // hold at a window edge/corner, then drag to resize
    public var windowThreeFingerDrag = false   // three fingers on a window move it (replaces 3-finger swipes there)
    public var windowSnap = true               // drag a window to a screen edge/corner to tile it; double-tap title bar maximizes
    public var touchMagnet = true              // taps near a small control snap to it
    public var touchRipple = true              // brief circle at each new contact
    public var dragLock = false                // lifting during a drag keeps it held for dragLockTimeout; touch again to continue
    public var dragLockTimeout = 1.5           // seconds
    public var holdToSelect = false            // hold, then drag selects by word; right-click moves to release
    public var tripleTapSelectLine = true      // third quick tap sends a triple-click
    public var grabZone = 24.0                 // points around a window edge that can be grabbed
    public var grabHoldDelay = 0.25            // seconds to hold before the edge grab engages
    public var magnetRadius = 12.0             // points

    /// Post real trackpad-style magnify/rotate events for two-finger pinch instead of shortcuts.
    public var nativeGestures = false
    /// Experimental: drive Spaces / Mission Control with dock-swipe events that follow the fingers.
    public var nativeSwipes = false
    /// Set by the calibration routine. When present it replaces `rotation`.
    public var calibration: Calibration?

    // Device (advanced; edit the JSON file)
    public var vendorID = 0x284B
    public var productID = 0x8300

    /// Only user overrides are stored, so future default changes still apply to untouched gestures.
    public var bindings: [String: Shortcut] = [:]

    public init() {}

    public func shortcut(for id: GestureID) -> Shortcut {
        bindings[id.rawValue] ?? id.defaultShortcut
    }

    public mutating func setShortcut(_ s: Shortcut, for id: GestureID) {
        if s == id.defaultShortcut { bindings.removeValue(forKey: id.rawValue) }
        else { bindings[id.rawValue] = s }
    }

    public mutating func resetBindings() { bindings = [:] }

    /// Resets sensitivity values to defaults, keeping device/display choices and shortcuts.
    public mutating func resetSensitivity() {
        let d = TouchConfig()
        scrollSpeed = d.scrollSpeed; invertScroll = d.invertScroll
        momentumScroll = d.momentumScroll; twoFingerTapRightClick = d.twoFingerTapRightClick
        moveThreshold = d.moveThreshold; rightClickOnHold = d.rightClickOnHold
        longPressDelay = d.longPressDelay; doubleTapWindow = d.doubleTapWindow
        swipeDistance = d.swipeDistance; zoomStep = d.zoomStep; edgeWidth = d.edgeWidth
        grabZone = d.grabZone; grabHoldDelay = d.grabHoldDelay; magnetRadius = d.magnetRadius
    }

    /// Returns a copy with every value forced into a sane range (hand-edited files, old versions).
    public func sanitized() -> TouchConfig {
        var c = self
        if ![0, 90, 180, 270].contains(c.rotation) { c.rotation = 0 }
        c.scrollSpeed = min(max(c.scrollSpeed, 0.05), 10)
        c.moveThreshold = min(max(c.moveThreshold, 1), 100)
        c.longPressDelay = min(max(c.longPressDelay, 0.1), 5)
        c.doubleTapWindow = min(max(c.doubleTapWindow, 0.05), 2)
        c.swipeDistance = min(max(c.swipeDistance, 0.01), 0.5)
        c.zoomStep = min(max(c.zoomStep, 1.02), 2)
        c.edgeWidth = min(max(c.edgeWidth, 0.003), 0.1)
        c.grabZone = min(max(c.grabZone, 8), 80)
        c.grabHoldDelay = min(max(c.grabHoldDelay, 0.1), 1)
        c.magnetRadius = min(max(c.magnetRadius, 2), 40)
        if let cal = c.calibration, !cal.isValid { c.calibration = nil }
        return c
    }

    // Tolerant decoding: missing keys fall back to defaults so old config files keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TouchConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        gesturesEnabled = try c.decodeIfPresent(Bool.self, forKey: .gesturesEnabled) ?? d.gesturesEnabled
        displayID = try c.decodeIfPresent(UInt32.self, forKey: .displayID)
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? d.rotation
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? d.scrollSpeed
        invertScroll = try c.decodeIfPresent(Bool.self, forKey: .invertScroll) ?? d.invertScroll
        momentumScroll = try c.decodeIfPresent(Bool.self, forKey: .momentumScroll) ?? d.momentumScroll
        twoFingerTapRightClick = try c.decodeIfPresent(Bool.self, forKey: .twoFingerTapRightClick) ?? d.twoFingerTapRightClick
        moveThreshold = try c.decodeIfPresent(Double.self, forKey: .moveThreshold) ?? d.moveThreshold
        rightClickOnHold = try c.decodeIfPresent(Bool.self, forKey: .rightClickOnHold) ?? d.rightClickOnHold
        longPressDelay = try c.decodeIfPresent(Double.self, forKey: .longPressDelay) ?? d.longPressDelay
        doubleTapWindow = try c.decodeIfPresent(Double.self, forKey: .doubleTapWindow) ?? d.doubleTapWindow
        swipeDistance = try c.decodeIfPresent(Double.self, forKey: .swipeDistance) ?? d.swipeDistance
        zoomStep = try c.decodeIfPresent(Double.self, forKey: .zoomStep) ?? d.zoomStep
        edgeWidth = try c.decodeIfPresent(Double.self, forKey: .edgeWidth) ?? d.edgeWidth
        windowEdgeGrab = try c.decodeIfPresent(Bool.self, forKey: .windowEdgeGrab) ?? d.windowEdgeGrab
        windowThreeFingerDrag = try c.decodeIfPresent(Bool.self, forKey: .windowThreeFingerDrag) ?? d.windowThreeFingerDrag
        windowSnap = try c.decodeIfPresent(Bool.self, forKey: .windowSnap) ?? d.windowSnap
        touchMagnet = try c.decodeIfPresent(Bool.self, forKey: .touchMagnet) ?? d.touchMagnet
        touchRipple = try c.decodeIfPresent(Bool.self, forKey: .touchRipple) ?? d.touchRipple
        dragLock = try c.decodeIfPresent(Bool.self, forKey: .dragLock) ?? d.dragLock
        dragLockTimeout = try c.decodeIfPresent(Double.self, forKey: .dragLockTimeout) ?? d.dragLockTimeout
        holdToSelect = try c.decodeIfPresent(Bool.self, forKey: .holdToSelect) ?? d.holdToSelect
        tripleTapSelectLine = try c.decodeIfPresent(Bool.self, forKey: .tripleTapSelectLine) ?? d.tripleTapSelectLine
        grabZone = try c.decodeIfPresent(Double.self, forKey: .grabZone) ?? d.grabZone
        grabHoldDelay = try c.decodeIfPresent(Double.self, forKey: .grabHoldDelay) ?? d.grabHoldDelay
        magnetRadius = try c.decodeIfPresent(Double.self, forKey: .magnetRadius) ?? d.magnetRadius
        nativeGestures = try c.decodeIfPresent(Bool.self, forKey: .nativeGestures) ?? d.nativeGestures
        nativeSwipes = try c.decodeIfPresent(Bool.self, forKey: .nativeSwipes) ?? d.nativeSwipes
        calibration = try? c.decodeIfPresent(Calibration.self, forKey: .calibration)
        vendorID = try c.decodeIfPresent(Int.self, forKey: .vendorID) ?? d.vendorID
        productID = try c.decodeIfPresent(Int.self, forKey: .productID) ?? d.productID
        bindings = try c.decodeIfPresent([String: Shortcut].self, forKey: .bindings) ?? [:]
        self = sanitized()
    }
}

/// Loads and saves the config file (default: ~/Library/Application Support/touchd/config.json).
public final class ConfigStore {
    public let url: URL

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("touchd/config.json")
    }

    public init(url: URL = ConfigStore.defaultURL) { self.url = url }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Returns the stored config, or defaults when missing. A corrupt file is moved aside (`.bad`).
    public func load() -> TouchConfig {
        guard let data = try? Data(contentsOf: url) else { return TouchConfig() }
        do {
            return try JSONDecoder().decode(TouchConfig.self, from: data)
        } catch {
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            return TouchConfig()
        }
    }

    @discardableResult
    public func save(_ config: TouchConfig) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try enc.encode(config).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
