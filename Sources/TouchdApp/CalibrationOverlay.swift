import AppKit

/// Full-display panel that shows one calibration target at a time. Main thread only.
/// A mouse click or Esc cancels; touches never reach it because input injection is suspended.
@MainActor
final class CalibrationOverlay {
    private var panel: NSPanel?
    private var view: TargetView?
    private var monitors: [Any] = []

    var isVisible: Bool { panel != nil }

    /// `bounds` is the display rect in global top-left coordinates.
    func show(bounds: CGRect, onCancel: @escaping () -> Void) {
        hide()
        let h = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: bounds.minX, y: h - bounds.maxY, width: bounds.width, height: bounds.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(0.82)
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let v = TargetView(frame: NSRect(origin: .zero, size: frame.size))
        v.onCancel = onCancel
        p.contentView = v
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
        panel = p; view = v

        let esc: (NSEvent) -> Bool = { $0.keyCode == 53 }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            if esc(e) { onCancel(); return nil }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { e in
            if esc(e) { DispatchQueue.main.async(execute: onCancel) }
        }) { monitors.append(m) }
    }

    /// `target` is normalized (0...1, top-left origin) within the display.
    func setTarget(_ target: CGPoint, step: Int, of total: Int) {
        view?.target = target
        view?.caption = "Touch the centre of the target with one finger (\(step) of \(total))"
        view?.needsDisplay = true
    }

    func hide() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil; view = nil
    }
}

private final class TargetView: NSView {
    var target = CGPoint(x: 0.5, y: 0.5)
    var caption = ""
    var onCancel: (() -> Void)?

    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onCancel?() }

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: target.x * bounds.width, y: target.y * bounds.height)
        NSColor.controlAccentColor.setStroke()
        for r in [36.0, 18.0] {
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ring.lineWidth = 3; ring.stroke()
        }
        NSColor.white.setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: c.x - 52, y: c.y)); cross.line(to: CGPoint(x: c.x + 52, y: c.y))
        cross.move(to: CGPoint(x: c.x, y: c.y - 52)); cross.line(to: CGPoint(x: c.x, y: c.y + 52))
        cross.lineWidth = 1.5; cross.stroke()

        let style = NSMutableParagraphStyle(); style.alignment = .center
        func text(_ s: String, size: CGFloat, color: NSColor, y: CGFloat) {
            let attr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color, .paragraphStyle: style,
            ]
            (s as NSString).draw(in: NSRect(x: 0, y: y, width: bounds.width, height: size * 1.5), withAttributes: attr)
        }
        // Keep the text away from the centre target.
        let y = bounds.height * (abs(target.y - 0.5) < 0.2 ? 0.25 : 0.46)
        text(caption, size: 28, color: .white, y: y)
        text("Click the mouse or press Esc to cancel", size: 16, color: NSColor.white.withAlphaComponent(0.7), y: y + 48)
    }
}
