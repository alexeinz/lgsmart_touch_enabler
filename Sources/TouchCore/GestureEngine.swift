import CoreGraphics
import Foundation

public enum MouseEventKind: Sendable { case move, leftDown, leftUp, leftDrag, rightDown, rightUp }

/// Where the engine sends synthesized input. The real implementation posts CGEvents; tests record.
public protocol EventSink: AnyObject {
    func mouse(_ kind: MouseEventKind, at p: CGPoint, clicks: Int)
    func scroll(dx: Int, dy: Int)
    func key(_ code: UInt16, flags: CGEventFlags)
}

/// Turns a stream of finger positions (screen points) into clicks, drags, scrolls and shortcuts.
/// Pure logic: no HID, no CoreGraphics event posting, time and timers are injected.
public final class GestureEngine {
    public typealias Cancel = () -> Void
    public typealias Scheduler = (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Cancel

    private enum Mode { case idle, pending, dragging, two, multi, consumed }
    private enum TwoMode { case undecided, scroll, pinch }

    private let sink: EventSink
    private let config: () -> TouchConfig
    private let schedule: Scheduler
    private let now: () -> Date
    public var log: ((String) -> Void)?
    /// Display rectangle in the same coordinate space as the points. `.zero` disables edge swipes.
    public var displayBounds = CGRect.zero

    private var mode = Mode.idle
    private var twoMode = TwoMode.undecided
    private var startPt = CGPoint.zero
    private var lastPt = CGPoint.zero
    private var baseC = CGPoint.zero      // gesture baseline centroid
    private var baseS: CGFloat = 0        // gesture baseline spread
    private var refS: CGFloat = 0         // pinch reference spread (zoom steps)
    private var lastC = CGPoint.zero      // last centroid, for scrolling
    private var multiN = 0
    private var fired = false
    private var edgeStart: GestureID?     // set while a single finger that began at an enabled edge is still pending
    private var lastTapTime = Date.distantPast
    private var lastTapPt = CGPoint.zero
    private var cancelLongPress: Cancel?
    private var scrollRemX = 0.0, scrollRemY = 0.0

    // Fixed geometry, relative to display width.
    private let scrollStart: CGFloat = 0.006
    private let pinchStart: CGFloat = 0.010
    private let multiPinchIn: CGFloat = 0.7
    private let multiPinchOut: CGFloat = 1.4
    private let doubleTapRadius: CGFloat = 30

    public init(sink: EventSink,
                config: @escaping () -> TouchConfig,
                schedule: @escaping Scheduler,
                now: @escaping () -> Date = Date.init) {
        self.sink = sink
        self.config = config
        self.schedule = schedule
        self.now = now
    }

    /// Feed the current set of touching fingers (screen points). Call whenever anything changes.
    public func update(points pts: [CGPoint], displayWidth W: CGFloat) {
        let cfg = config()
        let n = pts.count
        if n == 0 { finish(cfg); return }

        let c = Self.centroid(pts)
        let s = Self.spread(pts, c)

        switch mode {
        case .idle:
            if n == 1 { beginPending(pts[0], cfg) }
            else if n == 2 { beginTwo(c, s) }
            else { beginMulti(n, c, s) }

        case .pending:
            if n == 1 {
                if let edge = edgeStart, checkEdge(edge, pts[0], W, cfg) { break }
                if Self.dist(pts[0], startPt) > CGFloat(cfg.moveThreshold) {
                    endLongPress()
                    sink.mouse(.leftDown, at: startPt, clicks: 1)
                    sink.mouse(.leftDrag, at: pts[0], clicks: 1)
                    lastPt = pts[0]
                    mode = .dragging
                }
            } else if n == 2 { beginTwo(c, s) }
            else { beginMulti(n, c, s) }

        case .dragging:
            if n == 1 { sink.mouse(.leftDrag, at: pts[0], clicks: 1); lastPt = pts[0] }

        case .two:
            if n == 2 { handleTwo(c, s, W, cfg) }
            else if n >= 3 { beginMulti(n, c, s) }
            else { mode = .consumed }

        case .multi:
            if n == multiN { handleMulti(c, s, W, cfg) }
            else if n >= 3 { multiN = n; baseC = c; baseS = s }   // finger count changed: re-baseline
            else { mode = .consumed }

        case .consumed:
            break
        }
    }

    /// Release anything held (e.g. a drag in progress). Call when disabling or shutting down.
    public func reset() {
        endLongPress()
        if mode == .dragging { sink.mouse(.leftUp, at: lastPt, clicks: 1) }
        mode = .idle; fired = false; multiN = 0; edgeStart = nil
        scrollRemX = 0; scrollRemY = 0
    }

    // MARK: - State transitions

    private func beginPending(_ p: CGPoint, _ cfg: TouchConfig) {
        startPt = p; lastPt = p
        mode = .pending
        edgeStart = edgeZone(p, cfg)
        if cfg.rightClickOnHold {
            cancelLongPress = schedule(cfg.longPressDelay) { [weak self] in self?.longPressFired() }
        }
    }

    private func longPressFired() {
        guard mode == .pending else { return }
        log?("right-click")
        sink.mouse(.rightDown, at: startPt, clicks: 1)
        sink.mouse(.rightUp, at: startPt, clicks: 1)
        mode = .consumed
    }

    /// Which enabled edge zone `p` starts in, if any.
    private func edgeZone(_ p: CGPoint, _ cfg: TouchConfig) -> GestureID? {
        let b = displayBounds
        guard cfg.gesturesEnabled, b.width > 0, b.height > 0 else { return nil }
        let w = CGFloat(cfg.edgeWidth) * b.width
        let candidates: [(GestureID, Bool)] = [
            (.edgeLeft, p.x - b.minX <= w), (.edgeRight, b.maxX - p.x <= w),
            (.edgeTop, p.y - b.minY <= w), (.edgeBottom, b.maxY - p.y <= w),
        ]
        return candidates.first { $0.1 && !cfg.shortcut(for: $0.0).isDisabled }?.0
    }

    /// Handles a pending finger that started at an edge. Returns true while it owns the gesture
    /// (fired, or still moving inward). Motion that isn't mostly inward cancels it and becomes a normal drag.
    private func checkEdge(_ edge: GestureID, _ p: CGPoint, _ W: CGFloat, _ cfg: TouchConfig) -> Bool {
        let dx = p.x - startPt.x, dy = p.y - startPt.y
        let inward: CGFloat
        switch edge {
        case .edgeLeft: inward = dx
        case .edgeRight: inward = -dx
        case .edgeTop: inward = dy
        default: inward = -dy
        }
        let d = Self.dist(p, startPt)
        if inward > CGFloat(cfg.swipeDistance) * W {
            endLongPress()
            log?(edge.rawValue)
            fire(edge, cfg)
            mode = .consumed
            edgeStart = nil
            return true
        }
        if d > CGFloat(cfg.moveThreshold) && inward < 0.7 * d { edgeStart = nil; return false }
        return d <= CGFloat(cfg.moveThreshold) || inward >= 0.7 * d
    }

    private func endLongPress() { cancelLongPress?(); cancelLongPress = nil }

    private func beginTwo(_ c: CGPoint, _ s: CGFloat) {
        endLongPress()
        mode = .two; twoMode = .undecided
        baseC = c; baseS = s; refS = s; lastC = c
    }

    private func beginMulti(_ n: Int, _ c: CGPoint, _ s: CGFloat) {
        endLongPress()
        if mode != .multi { fired = false }
        mode = .multi
        multiN = n; baseC = c; baseS = s
    }

    private func finish(_ cfg: TouchConfig) {
        endLongPress()
        if mode == .pending {
            var clicks = 1
            if now().timeIntervalSince(lastTapTime) < cfg.doubleTapWindow,
               Self.dist(lastTapPt, startPt) < doubleTapRadius { clicks = 2 }
            log?("tap x\(clicks)")
            sink.mouse(.move, at: startPt, clicks: 1)
            sink.mouse(.leftDown, at: startPt, clicks: clicks)
            sink.mouse(.leftUp, at: startPt, clicks: clicks)
            lastTapTime = clicks == 2 ? .distantPast : now()
            lastTapPt = startPt
        } else if mode == .dragging {
            sink.mouse(.leftUp, at: lastPt, clicks: 1)
        }
        mode = .idle; fired = false; multiN = 0; edgeStart = nil
        scrollRemX = 0; scrollRemY = 0
    }

    // MARK: - Two fingers: scroll or pinch

    private func handleTwo(_ c: CGPoint, _ s: CGFloat, _ W: CGFloat, _ cfg: TouchConfig) {
        switch twoMode {
        case .undecided:
            let dc = Self.dist(c, baseC), ds = abs(s - baseS)
            if cfg.gesturesEnabled && ds > pinchStart * W && ds > dc {
                twoMode = .pinch; refS = s
            } else if dc > scrollStart * W {
                twoMode = .scroll; lastC = baseC
                emitScroll(c.x - lastC.x, c.y - lastC.y, cfg); lastC = c
            }
        case .scroll:
            emitScroll(c.x - lastC.x, c.y - lastC.y, cfg); lastC = c
        case .pinch:
            let r = s / max(refS, 1)
            let step = CGFloat(cfg.zoomStep)
            if r > step { log?("zoom in"); fire(.pinch2Out, cfg); refS = s }
            else if r < 1 / step { log?("zoom out"); fire(.pinch2In, cfg); refS = s }
        }
    }

    /// Scroll with sub-pixel accumulation so slow speeds don't round to nothing.
    private func emitScroll(_ dx: CGFloat, _ dy: CGFloat, _ cfg: TouchConfig) {
        let k = cfg.scrollSpeed * (cfg.invertScroll ? -1 : 1)
        scrollRemX += Double(dx) * k
        scrollRemY += Double(dy) * k
        let ix = Int(scrollRemX.rounded(.towardZero)), iy = Int(scrollRemY.rounded(.towardZero))
        scrollRemX -= Double(ix); scrollRemY -= Double(iy)
        if ix != 0 || iy != 0 { sink.scroll(dx: ix, dy: iy) }
    }

    // MARK: - Three or more fingers: swipe / pinch

    private func handleMulti(_ c: CGPoint, _ s: CGFloat, _ W: CGFloat, _ cfg: TouchConfig) {
        guard cfg.gesturesEnabled, !fired, (3...5).contains(multiN) else { return }
        let dx = c.x - baseC.x, dy = c.y - baseC.y
        if max(abs(dx), abs(dy)) > CGFloat(cfg.swipeDistance) * W {
            fired = true
            let ids = GestureID.swipeIDs[multiN]!   // [left, right, up, down]
            let id: GestureID
            if abs(dx) > abs(dy) { id = dx < 0 ? ids[0] : ids[1] }
            else { id = dy < 0 ? ids[2] : ids[3] }
            log?("\(id.rawValue)")
            fire(id, cfg)
        } else if multiN >= 4 {
            let r = s / max(baseS, 1)
            if r < multiPinchIn { fired = true; log?("pinch4In"); fire(.pinch4In, cfg) }
            else if r > multiPinchOut { fired = true; log?("pinch4Out"); fire(.pinch4Out, cfg) }
        }
    }

    private func fire(_ id: GestureID, _ cfg: TouchConfig) {
        let sc = cfg.shortcut(for: id)
        guard let code = sc.keyCode else { return }
        sink.key(code, flags: sc.cgFlags)
    }

    // MARK: - Geometry helpers

    static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func centroid(_ pts: [CGPoint]) -> CGPoint {
        CGPoint(x: pts.map { $0.x }.reduce(0, +) / CGFloat(pts.count),
                y: pts.map { $0.y }.reduce(0, +) / CGFloat(pts.count))
    }

    static func spread(_ pts: [CGPoint], _ c: CGPoint) -> CGFloat {
        pts.map { dist($0, c) }.reduce(0, +) / CGFloat(pts.count)
    }
}
