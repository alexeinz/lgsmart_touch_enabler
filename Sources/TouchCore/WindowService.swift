import CoreGraphics
import Foundation

/// A window as the engine sees it. Frames are in screen points, origin top-left (same space as touches).
public struct WindowInfo: Equatable {
    public var id: Int
    public var frame: CGRect
    public var titleBar: CGRect
    public init(id: Int, frame: CGRect, titleBar: CGRect) {
        self.id = id; self.frame = frame; self.titleBar = titleBar
    }
}

/// Window and accessibility operations the engine needs. The real implementation uses the
/// Accessibility API; tests use a fake.
public protocol WindowService: AnyObject {
    /// Topmost window under `p`, if any.
    func window(at p: CGPoint) -> WindowInfo?
    func setFrame(_ id: Int, _ frame: CGRect)
    /// Area windows may be tiled into (display minus menu bar and Dock) around `p`.
    func usableBounds(containing p: CGPoint) -> CGRect
    /// Centre of the nearest small clickable control within `radius` of `p`, or nil to leave the tap alone.
    func magnet(near p: CGPoint, radius: CGFloat) -> CGPoint?
    /// Faint highlight while an edge/corner is held, or the tiling preview; nil hides it.
    func showHandle(_ rect: CGRect?)
    func showPreview(_ rect: CGRect?)
}

/// Which sides of a window a touch grabbed.
public struct GrabEdges: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = GrabEdges(rawValue: 1), right = GrabEdges(rawValue: 2)
    public static let top = GrabEdges(rawValue: 4), bottom = GrabEdges(rawValue: 8)

    /// Edges of `frame` that `p` is within `zone` of (inside or just outside). The top edge alone is
    /// excluded because it is the title bar; the top counts only as part of a corner.
    public static func at(_ p: CGPoint, in frame: CGRect, zone: CGFloat) -> GrabEdges {
        guard frame.insetBy(dx: -zone, dy: -zone).contains(p) else { return [] }
        var e: GrabEdges = []
        if abs(p.x - frame.minX) <= zone { e.insert(.left) }
        if abs(p.x - frame.maxX) <= zone { e.insert(.right) }
        if abs(p.y - frame.maxY) <= zone { e.insert(.bottom) }
        if abs(p.y - frame.minY) <= zone { e.insert(.top) }
        if e == .top { return [] }
        if e.contains(.top) && !(e.contains(.left) || e.contains(.right)) { e.remove(.top) }
        return e
    }

    /// New frame after moving the grabbed edges by (dx, dy), never smaller than `minSize`.
    public func resize(_ f: CGRect, dx: CGFloat, dy: CGFloat, minSize: CGFloat = 160) -> CGRect {
        var r = f
        if contains(.left) { let w = max(f.width - dx, minSize); r.origin.x = f.maxX - w; r.size.width = w }
        if contains(.right) { r.size.width = max(f.width + dx, minSize) }
        if contains(.top) { let h = max(f.height - dy, minSize); r.origin.y = f.maxY - h; r.size.height = h }
        if contains(.bottom) { r.size.height = max(f.height + dy, minSize) }
        return r
    }
}

public enum Snap {
    /// Tiling rectangle for a pointer released at `p`, or nil if it isn't in an edge/corner zone.
    /// Corners give quarters, left/right give halves, the top edge maximizes.
    public static func rect(for p: CGPoint, in b: CGRect, margin: CGFloat = 24, corner: CGFloat = 120) -> CGRect? {
        guard b.width > 0, b.height > 0 else { return nil }
        let l = p.x - b.minX <= margin, r = b.maxX - p.x <= margin
        let t = p.y - b.minY <= margin, bt = b.maxY - p.y <= margin
        let nearLeftCorner = p.x - b.minX <= corner, nearRightCorner = b.maxX - p.x <= corner
        let nearTopCorner = p.y - b.minY <= corner, nearBottomCorner = b.maxY - p.y <= corner
        let hw = b.width / 2, hh = b.height / 2
        if (l && nearTopCorner) || (t && nearLeftCorner) { return CGRect(x: b.minX, y: b.minY, width: hw, height: hh) }
        if (r && nearTopCorner) || (t && nearRightCorner) { return CGRect(x: b.minX + hw, y: b.minY, width: hw, height: hh) }
        if (l && nearBottomCorner) || (bt && nearLeftCorner) { return CGRect(x: b.minX, y: b.minY + hh, width: hw, height: hh) }
        if (r && nearBottomCorner) || (bt && nearRightCorner) { return CGRect(x: b.minX + hw, y: b.minY + hh, width: hw, height: hh) }
        if l { return CGRect(x: b.minX, y: b.minY, width: hw, height: b.height) }
        if r { return CGRect(x: b.minX + hw, y: b.minY, width: hw, height: b.height) }
        if t { return b }
        return nil
    }
}
