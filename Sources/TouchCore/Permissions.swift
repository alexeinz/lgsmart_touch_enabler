import ApplicationServices
import Foundation
import IOKit.hid

/// macOS privacy permissions touchd needs.
public enum Permissions {
    public enum AccessState: String, Sendable {
        case granted, denied, notDetermined
    }

    /// Needed to post mouse/keyboard events.
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Needed to read the touchscreen's HID reports.
    public static var inputMonitoringState: AccessState {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    public static var inputMonitoringGranted: Bool { inputMonitoringState == .granted }

    /// Shows the system prompt the first time. Once the user has answered (or dismissed) it, macOS never
    /// prompts again, so in that case this returns false and the caller should open System Settings.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        // Both calls register the app in the Input Monitoring list; a listen-only event tap does too.
        let fresh = inputMonitoringState == .notDetermined
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        _ = CGRequestListenEventAccess()
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                       eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                       callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil) {
            CFMachPortInvalidate(tap)
        }
        return fresh
    }

    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let inputMonitoringSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
}
