import AppKit
import QuartzCore
import TouchCore

/// Click-through overlays: edge-grab handle, tiling preview and touch ripples. Main thread only.
@MainActor
final class OverlayController {
    private lazy var handle = makePanel(fill: nil, border: NSColor.controlAccentColor)
    private lazy var preview = makePanel(fill: NSColor.controlAccentColor.withAlphaComponent(0.18), border: NSColor.controlAccentColor.withAlphaComponent(0.7))
    private var ripplePanels: [NSPanel] = []
    private var down = 0

    private func makePanel(fill: NSColor?, border: NSColor) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true; p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let v = NSView(); v.wantsLayer = true
        v.layer?.cornerRadius = 10; v.layer?.borderWidth = 3
        v.layer?.borderColor = border.cgColor
        v.layer?.backgroundColor = fill?.cgColor
        p.contentView = v
        return p
    }

    /// Top-left global rect -> Cocoa rect.
    private func cocoa(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    func setHandle(_ r: CGRect?) { show(handle, r) }
    func setPreview(_ r: CGRect?) { show(preview, r) }

    private func show(_ p: NSPanel, _ r: CGRect?) {
        guard let r else { p.orderOut(nil); return }
        p.setFrame(cocoa(r), display: true)
        p.orderFrontRegardless()
    }

    /// Ripple for every newly landed finger.
    func contacts(_ pts: [CGPoint]) {
        if pts.count > down, let p = pts.last { ripple(at: p) }
        down = pts.count
    }

    private func ripple(at p: CGPoint) {
        let d: CGFloat = 56
        let panel = NSPanel(contentRect: cocoa(CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let v = NSView(frame: NSRect(x: 0, y: 0, width: d, height: d)); v.wantsLayer = true
        let l = CALayer(); l.frame = v.bounds; l.cornerRadius = d / 2
        l.borderWidth = 2.5; l.borderColor = NSColor.controlAccentColor.cgColor
        l.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        v.layer?.addSublayer(l); panel.contentView = v
        panel.orderFrontRegardless()
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.4; scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1.0; fade.toValue = 0.0
        let g = CAAnimationGroup(); g.animations = [scale, fade]; g.duration = 0.45
        g.timingFunction = CAMediaTimingFunction(name: .easeOut); g.isRemovedOnCompletion = false; g.fillMode = .forwards
        l.add(g, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { panel.orderOut(nil) }
    }
}
