import AppKit
import ApplicationServices

/// Accessibility-API implementation of `WindowService`. Main thread only. Needs the Accessibility permission.
public final class AXWindowService: WindowService {
    public var onHandle: ((CGRect?) -> Void)?
    public var onPreview: ((CGRect?) -> Void)?

    private let system = AXUIElementCreateSystemWide()
    private var cache: [Int: AXUIElement] = [:]
    private static let actionable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuBarItem", "AXPopUpButton", "AXLink",
        "AXTab", "AXMenuItem", "AXDisclosureTriangle", "AXSegmentedControl", "AXComboBox"
    ]

    public init() { AXUIElementSetMessagingTimeout(system, 0.15) }

    // MARK: WindowService

    public func window(at p: CGPoint) -> WindowInfo? {
        let probes = [p, CGPoint(x: p.x + 14, y: p.y), CGPoint(x: p.x - 14, y: p.y),
                      CGPoint(x: p.x, y: p.y + 14), CGPoint(x: p.x, y: p.y - 14)]
        for q in probes {
            guard let el = element(at: q), let win = Self.window(of: el), let f = Self.frame(of: win) else { continue }
            guard f.insetBy(dx: -30, dy: -30).contains(p) else { continue }
            let id = Int(CFHash(win))
            cache[id] = win
            return WindowInfo(id: id, frame: f, titleBar: CGRect(x: f.minX, y: f.minY, width: f.width, height: 28))
        }
        return nil
    }

    public func setFrame(_ id: Int, _ frame: CGRect) {
        guard let win = cache[id] else { return }
        var pos = frame.origin, size = frame.size
        if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s) }
    }

    public func usableBounds(containing p: CGPoint) -> CGRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        let h = primary.frame.height
        func top(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        for s in NSScreen.screens where top(s.frame).contains(p) { return top(s.visibleFrame) }
        return top(primary.visibleFrame)
    }

    public func magnet(near p: CGPoint, radius: CGFloat) -> CGPoint? {
        if let el = element(at: p) {
            let role = Self.string(el, kAXRoleAttribute)
            if Self.actionable.contains(role) { return nil }                       // already on a control
            if ["AXTextField", "AXTextArea", "AXScrollBar", "AXSlider", "AXWebArea"].contains(role) { return nil }
        }
        var best: (pt: CGPoint, d: CGFloat)?
        for r in [radius / 2, radius] {
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                let q = CGPoint(x: p.x + r * CGFloat(cos(a)), y: p.y + r * CGFloat(sin(a)))
                guard let el = element(at: q), Self.actionable.contains(Self.string(el, kAXRoleAttribute)),
                      let f = Self.frame(of: el), f.width <= 120, f.height <= 60 else { continue }
                let c = CGPoint(x: f.midX, y: f.midY)
                let d = hypot(c.x - p.x, c.y - p.y)
                if best == nil || d < best!.d { best = (c, d) }
            }
            if best != nil { break }
        }
        return best?.pt
    }

    public func showHandle(_ rect: CGRect?) { onHandle?(rect) }
    public func showPreview(_ rect: CGRect?) { onPreview?(rect) }

    // MARK: AX helpers

    private func element(at p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &el) == .success else { return nil }
        return el
    }

    private static func window(of el: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = el
        for _ in 0..<12 {
            guard let c = cur else { return nil }
            if string(c, kAXRoleAttribute) == "AXWindow" { return c }
            var w: CFTypeRef?
            if AXUIElementCopyAttributeValue(c, kAXWindowAttribute as CFString, &w) == .success, let w { return (w as! AXUIElement) }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &parent) == .success, let parent else { return nil }
            cur = (parent as! AXUIElement)
        }
        return nil
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return "" }
        return v as? String ?? ""
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
