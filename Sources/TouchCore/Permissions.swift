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

    /// TCC service names for the two grants, as `tccutil` spells them.
    public static let tccServices = ["Accessibility", "ListenEvent"]

    /// One `tccutil` argument list per grant. macOS keeps grants after an app is deleted or re-signed,
    /// so stale entries have to be removed explicitly.
    public static func resetArguments(bundleID: String) -> [[String]] {
        tccServices.map { ["reset", $0, bundleID] }
    }

    /// Removes this bundle ID's Accessibility and Input Monitoring entries. Returns false if any reset failed.
    /// The running process keeps its cached state, so relaunch (or quit) afterwards.
    @discardableResult
    public static func reset(bundleID: String) -> Bool {
        var ok = true
        for args in resetArguments(bundleID: bundleID) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = args
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do { try task.run(); task.waitUntilExit() } catch { ok = false; continue }
            if task.terminationStatus != 0 { ok = false }
        }
        return ok
    }

    /// Identifies who signed the running binary: the leaf certificate for a real identity, the code hash for ad-hoc.
    /// macOS ties privacy grants to this, so when it changes the old grants silently stop matching.
    public static func signingFingerprint() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        if let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            let data = SecCertificateCopyData(leaf) as Data
            return "cert:" + data.hashHex
        }
        if let h = d[kSecCodeInfoUnique as String] as? Data { return "cdhash:" + h.hashHex }
        return nil
    }

    /// True when the signing identity changed since the last launch and a grant is missing, which means the
    /// missing grant is almost certainly a stale entry left by the previous identity and must be cleared.
    public static func shouldClearStaleGrants(stored: String?, current: String?, accessibility: Bool, inputMonitoring: Bool) -> Bool {
        guard let current, stored != current else { return false }
        return !accessibility || !inputMonitoring
    }

    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let inputMonitoringSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
}

private extension Data {
    var hashHex: String { map { String(format: "%02x", $0) }.joined() }
}
