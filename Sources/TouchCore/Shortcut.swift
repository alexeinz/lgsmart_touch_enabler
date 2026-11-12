import CoreGraphics
import Foundation

/// A keyboard shortcut that a gesture can trigger. `keyCode == nil` means "disabled".
public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16?
    public var flags: UInt64

    /// Modifier bits we care about (everything else in CGEventFlags is noise for synthesized keys).
    public static let relevantFlags: CGEventFlags = [
        .maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn,
    ]

    public static let disabled = Shortcut(keyCode: nil)

    public init(keyCode: UInt16?, flags: CGEventFlags = []) {
        self.keyCode = keyCode
        self.flags = flags.intersection(Shortcut.relevantFlags).rawValue
    }

    public var cgFlags: CGEventFlags { CGEventFlags(rawValue: flags) }
    public var isDisabled: Bool { keyCode == nil }

    public var displayString: String {
        guard let code = keyCode else { return "Disabled" }
        let f = cgFlags
        var s = ""
        if f.contains(.maskSecondaryFn) { s += "fn " }
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s + (Shortcut.keyNames[code] ?? "Key \(code)")
    }

    // MARK: Common key codes (ANSI layout)

    public static let kLeft: UInt16 = 123, kRight: UInt16 = 124, kDown: UInt16 = 125, kUp: UInt16 = 126
    public static let kEqual: UInt16 = 24, kMinus: UInt16 = 27, kF4: UInt16 = 118, kF11: UInt16 = 103

    static let ctrlFn: CGEventFlags = [.maskControl, .maskSecondaryFn]

    /// Ready-made shortcuts offered in the UI's preset menu.
    public static let presets: [(name: String, shortcut: Shortcut)] = [
        ("Next Space", Shortcut(keyCode: kRight, flags: ctrlFn)),
        ("Previous Space", Shortcut(keyCode: kLeft, flags: ctrlFn)),
        ("Mission Control", Shortcut(keyCode: kUp, flags: ctrlFn)),
        ("App Exposé", Shortcut(keyCode: kDown, flags: ctrlFn)),
        ("Launchpad", Shortcut(keyCode: kF4)),
        ("Show Desktop", Shortcut(keyCode: kF11)),
        ("Zoom In", Shortcut(keyCode: kEqual, flags: .maskCommand)),
        ("Zoom Out", Shortcut(keyCode: kMinus, flags: .maskCommand)),
        ("Back", Shortcut(keyCode: 33, flags: .maskCommand)),       // ⌘[
        ("Forward", Shortcut(keyCode: 30, flags: .maskCommand)),    // ⌘]
        ("Disabled", .disabled),
    ]

    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
