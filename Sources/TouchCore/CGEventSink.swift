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
}
