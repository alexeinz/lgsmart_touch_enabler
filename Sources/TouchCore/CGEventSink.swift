import CoreGraphics
import Foundation

/// Posts synthesized input to the system via CoreGraphics (needs Accessibility permission).
public final class CGEventSink: EventSink {
    private let src = CGEventSource(stateID: .hidSystemState)

    public init() {}

    public func mouse(_ kind: MouseEventKind, at p: CGPoint, clicks: Int) {
        let type: CGEventType, button: CGMouseButton
        switch kind {
        case .move: (type, button) = (.mouseMoved, .left)
        case .leftDown: (type, button) = (.leftMouseDown, .left)
        case .leftUp: (type, button) = (.leftMouseUp, .left)
        case .leftDrag: (type, button) = (.leftMouseDragged, .left)
        case .rightDown: (type, button) = (.rightMouseDown, .right)
        case .rightUp: (type, button) = (.rightMouseUp, .right)
        }
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.post(tap: .cghidEventTap)
    }

    public func scroll(dx: Int, dy: Int) {
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        e.post(tap: .cghidEventTap)
    }

    public func key(_ code: UInt16, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: Gesture events
    //
    // macOS has no public API for synthesizing trackpad gestures. These are plain CGEvents with the
    // (undocumented, but stable for many releases) gesture fields filled in. Field numbers:
    private enum F {
        static let type = 55          // event type: 29 = gesture, 30 = dock control
        static let subtype = 110      // 8 = magnify, 5 = rotate, 23 = dock swipe
        static let phase = 132
        static let value = 113        // magnification / rotation amount
        static let swipeAxis = 123
        static let swipeProgress = 124
        static let swipeProgressBits = 126
        static let swipeVelocityX = 129
        static let swipeVelocityY = 130
        static let swipePhase = 134
        static let swipeAxis2 = 165
        static let marker = 41
    }

    private func setInt(_ e: CGEvent, _ field: Int, _ v: Int64) {
        if let f = CGEventField(rawValue: UInt32(field)) { e.setIntegerValueField(f, value: v) }
    }

    private func setDouble(_ e: CGEvent, _ field: Int, _ v: Double) {
        if let f = CGEventField(rawValue: UInt32(field)) { e.setDoubleValueField(f, value: v) }
    }

    private func gesture(subtype: Int64, value: Double, phase: GesturePhase) {
        guard let e = CGEvent(source: nil) else { return }
        setInt(e, F.type, 29)
        setInt(e, F.subtype, subtype)
        setInt(e, F.phase, Int64(phase.rawValue))
        setDouble(e, F.value, value)
        e.post(tap: .cgSessionEventTap)
    }

    public func magnify(_ delta: Double, phase: GesturePhase) { gesture(subtype: 8, value: delta, phase: phase) }

    public func rotate(_ degrees: Double, phase: GesturePhase) { gesture(subtype: 5, value: degrees, phase: phase) }

    /// Experimental: the Dock expects a dock-control event paired with an empty gesture event.
    public func dockSwipe(_ axis: SwipeAxis, progress: Double, velocity: Double, phase: GesturePhase) {
        guard let swipe = CGEvent(source: nil), let pair = CGEvent(source: nil) else { return }
        setInt(swipe, F.type, 30)
        setInt(swipe, F.subtype, 23)
        setInt(swipe, F.marker, 33231)
        setInt(swipe, F.phase, Int64(phase.rawValue))
        setInt(swipe, F.swipePhase, Int64(phase.rawValue))
        setInt(swipe, F.swipeAxis, Int64(axis.rawValue))
        setInt(swipe, F.swipeAxis2, Int64(axis.rawValue))
        setDouble(swipe, F.swipeProgress, progress)
        setInt(swipe, F.swipeProgressBits, Int64(Float(progress).bitPattern))
        if phase == .ended {
            setDouble(swipe, F.swipeVelocityX, velocity)
            setDouble(swipe, F.swipeVelocityY, velocity)
        }
        setInt(pair, F.type, 29)
        setInt(pair, F.marker, 33231)
        swipe.post(tap: .cgSessionEventTap)
        pair.post(tap: .cgSessionEventTap)
    }
}
