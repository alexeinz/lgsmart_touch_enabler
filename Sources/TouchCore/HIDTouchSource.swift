import CoreGraphics
import Foundation
import IOKit.hid

/// Reads a USB/Bluetooth HID digitizer (multi-touch) and reports the set of touching fingers
/// as normalized (0...1, top-left origin) points. Must be used from the main thread.
public final class HIDTouchSource {
    private struct Finger { var tip = false, x = 0.0, y = 0.0, hasX = false, hasY = false }

    private var manager: IOHIDManager?
    private var fingers: [Int: Finger] = [:]
    private var connected = 0
    private var flushScheduled = false

    /// Called (main thread) after any change with the currently touching fingers.
    public var onChange: (([CGPoint]) -> Void)?
    /// Called when the device appears/disappears.
    public var onConnection: ((Bool) -> Void)?
    /// Raw element dump hook (used by `touchd dump`).
    public var onRawValue: ((_ page: Int, _ usage: Int, _ value: Int, _ parent: Int) -> Void)?

    public private(set) var isRunning = false
    public var isConnected: Bool { connected > 0 }

    public init() {}

    @discardableResult
    public func start(vendorID: Int, productID: Int) -> Bool {
        guard !isRunning else { return true }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { c, _, _, _ in
            guard let c else { return }
            let s = Unmanaged<HIDTouchSource>.fromOpaque(c).takeUnretainedValue()
            s.connected += 1
            s.onConnection?(true)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { c, _, _, _ in
            guard let c else { return }
            let s = Unmanaged<HIDTouchSource>.fromOpaque(c).takeUnretainedValue()
            s.connected = max(0, s.connected - 1)
            if s.connected == 0 { s.fingers.removeAll(); s.scheduleFlush() }
            s.onConnection?(s.connected > 0)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(mgr, { c, _, _, value in
            guard let c else { return }
            Unmanaged<HIDTouchSource>.fromOpaque(c).takeUnretainedValue().handle(value)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return false
        }
        manager = mgr
        isRunning = true
        return true
    }

    public func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerRegisterInputValueCallback(mgr, nil, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        isRunning = false
        connected = 0
        fingers.removeAll()
        onChange?([])
    }

    // MARK: - Parsing

    private func handle(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(el)), usage = Int(IOHIDElementGetUsage(el))
        let v = IOHIDValueGetIntegerValue(value)
        let parentKey: Int = IOHIDElementGetParent(el).map { Int(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
        onRawValue?(page, usage, v, parentKey)

        switch (page, usage) {
        case (0x0D, 0x54):                       // Contact Count
            if v == 0 { for k in fingers.keys { fingers[k]?.tip = false } }
        case (0x0D, 0x42):                       // Tip Switch
            fingers[parentKey, default: Finger()].tip = v != 0
        case (0x01, 0x30), (0x01, 0x31):         // X / Y
            let lo = Double(IOHIDElementGetLogicalMin(el)), hi = Double(IOHIDElementGetLogicalMax(el))
            guard hi > lo else { return }
            let n = min(max((Double(v) - lo) / (hi - lo), 0), 1)
            if usage == 0x30 { fingers[parentKey, default: Finger()].x = n; fingers[parentKey]?.hasX = true }
            else { fingers[parentKey, default: Finger()].y = n; fingers[parentKey]?.hasY = true }
        default:
            return
        }
        scheduleFlush()
    }

    /// Coalesce the burst of per-element callbacks of one report into a single update.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let pts = self.fingers
                .filter { $0.value.tip && $0.value.hasX && $0.value.hasY }
                .sorted { $0.key < $1.key }
                .map { CGPoint(x: $0.value.x, y: $0.value.y) }
            self.onChange?(pts)
        }
    }
}
