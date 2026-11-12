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

    private enum Mode { case idle, pending, held, grab, dragging, two, multi, consumed }
    private enum TwoMode { case undecided, scroll, pinch }

    private let sink: EventSink
    private let config: () -> TouchConfig
    private let schedule: Scheduler
    private let now: () -> Date
    public var log: ((String) -> Void)?
    /// Display rectangle in the same coordinate space as the points. `.zero` disables edge swipes.
    public var displayBounds = CGRect.zero
    /// Window/accessibility operations for the touch helpers. nil disables them all.
    public var windows: WindowService?

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
    private var twoStart = Date.distantPast
    private var velX = 0.0, velY = 0.0            // scroll velocity, output units per second
    private var lastScrollTime = Date.distantPast
    private var cancelMomentum: Cancel?
    private var momRemX = 0.0, momRemY = 0.0
    private var tapCount = 0
    private var grabCandidate: (win: WindowInfo, edges: GrabEdges)?
    private var grab: (win: WindowInfo, edges: GrabEdges)?
    private var cancelGrab: Cancel?
    private var titleWin: WindowInfo?             // window whose title bar the current one-finger drag started on
    private var dragWin: WindowInfo?              // window being moved by three fingers
    private var winDragC = CGPoint.zero
    private var restoreFrames: [Int: CGRect] = [:]

    // Fixed geometry, relative to display width.
    private let scrollStart: CGFloat = 0.006
    private let pinchStart: CGFloat = 0.010
    private let multiPinchIn: CGFloat = 0.7
    private let multiPinchOut: CGFloat = 1.4
    private let doubleTapRadius: CGFloat = 30
    private let twoTapMaxDuration: TimeInterval = 0.3
    private let momentumMinSpeed = 250.0          // flick speed needed to coast
    private let momentumStopSpeed = 40.0
    private let momentumTick: TimeInterval = 1.0 / 60
    private let momentumFriction = 0.95           // velocity kept per tick

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
        if n > 0 { stopMomentum() }
        if n == 0 { finish(cfg); return }

        let c = Self.centroid(pts)
        let s = Self.spread(pts, c)

        switch mode {
        case .idle:
            if n == 1 { beginPending(pts[0], cfg) }
            else if n == 2 { beginTwo(c, s) }
            else { beginMulti(n, c, s, cfg) }

        case .pending:
            if n == 1 {
                if let edge = edgeStart, checkEdge(edge, pts[0], W, cfg) { break }
                if Self.dist(pts[0], startPt) > CGFloat(cfg.moveThreshold) {
                    endLongPress()
                    sink.mouse(.leftDown, at: startPt, clicks: 1)
                    sink.mouse(.leftDrag, at: pts[0], clicks: 1)
                    lastPt = pts[0]
                    mode = .dragging
                    if cfg.windowSnap, let w = windows, let info = w.window(at: startPt), info.titleBar.contains(startPt) {
                        titleWin = info
                    }
                }
            } else if n == 2 { beginTwo(c, s) }
            else { beginMulti(n, c, s, cfg) }

        case .held:
            if n == 1 {
                if Self.dist(pts[0], startPt) > CGFloat(cfg.moveThreshold) {
                    log?("hold-drag select")
                    sink.mouse(.leftDown, at: startPt, clicks: 2)
                    sink.mouse(.leftDrag, at: pts[0], clicks: 2)
                    lastPt = pts[0]
                    mode = .dragging
                }
            } else if n == 2 { beginTwo(c, s) }
            else { beginMulti(n, c, s, cfg) }

        case .grab:
            if n == 1, let g = grab {
                let r = g.edges.resize(g.win.frame, dx: pts[0].x - startPt.x, dy: pts[0].y - startPt.y)
                windows?.setFrame(g.win.id, r)
                windows?.showHandle(r)
            } else { endGrab(); mode = .consumed }

        case .dragging:
            if n == 1 {
                let clicks = 1
                sink.mouse(.leftDrag, at: pts[0], clicks: clicks); lastPt = pts[0]
                if titleWin != nil, let w = windows {
                    w.showPreview(Snap.rect(for: pts[0], in: w.usableBounds(containing: pts[0])))
                }
            }

        case .two:
            if n == 2 { handleTwo(c, s, W, cfg) }
            else if n >= 3 { beginMulti(n, c, s, cfg) }
            else { endTwo(cfg); mode = .consumed }

        case .multi:
            if n == multiN { handleMulti(c, s, W, cfg) }
            else if n >= 3 { multiN = n; baseC = c; baseS = s; if n != 3 { endWinDrag() } }   // finger count changed: re-baseline
            else { endWinDrag(); mode = .consumed }

        case .consumed:
            break
        }
    }

    /// Release anything held (e.g. a drag in progress). Call when disabling or shutting down.
    public func reset() {
        endLongPress()
        stopMomentum()
        if mode == .dragging { sink.mouse(.leftUp, at: lastPt, clicks: 1) }
        endGrab(); titleWin = nil; windows?.showPreview(nil)
        dragWin = nil
        mode = .idle; fired = false; multiN = 0; edgeStart = nil
        scrollRemX = 0; scrollRemY = 0
    }

    // MARK: - State transitions

    private func beginPending(_ p: CGPoint, _ cfg: TouchConfig) {
        startPt = p; lastPt = p
        mode = .pending
        edgeStart = edgeZone(p, cfg)
        grabCandidate = nil; titleWin = nil
        if cfg.windowEdgeGrab, let w = windows, let info = w.window(at: p) {
            let e = GrabEdges.at(p, in: info.frame, zone: CGFloat(cfg.grabZone))
            if !e.isEmpty {
                grabCandidate = (info, e)
                cancelGrab = schedule(cfg.grabHoldDelay) { [weak self] in self?.grabFired() }
            }
        }
        if cfg.rightClickOnHold {
            cancelLongPress = schedule(cfg.longPressDelay) { [weak self] in self?.longPressFired() }
        }
    }

    private func grabFired() {
        guard mode == .pending, let g = grabCandidate else { return }
        endLongPress()
        log?("window edge grab")
        grab = g; mode = .grab; edgeStart = nil
        windows?.showHandle(g.win.frame)
    }

    private func endGrab() {
        if grab != nil { windows?.showHandle(nil) }
        grab = nil; grabCandidate = nil
    }

    private func endWinDrag() {
        guard let w = dragWin else { return }
        dragWin = nil
        windows?.showPreview(nil)
        if config().windowSnap, let svc = windows,
           let r = Snap.rect(for: winDragC, in: svc.usableBounds(containing: winDragC)) { svc.setFrame(w.id, r); log?("snap window") }
    }

    private func longPressFired() {
        guard mode == .pending else { return }
        if config().holdToSelect { log?("hold"); mode = .held; return }
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

    private func endLongPress() { cancelLongPress?(); cancelLongPress = nil; cancelGrab?(); cancelGrab = nil }

    private func beginTwo(_ c: CGPoint, _ s: CGFloat) {
        endLongPress()
        mode = .two; twoMode = .undecided
        baseC = c; baseS = s; refS = s; lastC = c
        twoStart = now(); lastScrollTime = twoStart; velX = 0; velY = 0
    }

    /// Called when a two-finger gesture ends (a finger lifted). Handles two-finger tap and flick momentum.
    private func endTwo(_ cfg: TouchConfig) {
        switch twoMode {
        case .undecided:
            if cfg.twoFingerTapRightClick, now().timeIntervalSince(twoStart) < twoTapMaxDuration {
                log?("two-finger tap: right-click")
                sink.mouse(.move, at: baseC, clicks: 1)
                sink.mouse(.rightDown, at: baseC, clicks: 1)
                sink.mouse(.rightUp, at: baseC, clicks: 1)
            }
        case .scroll:
            let speed = hypot(velX, velY)
            if cfg.momentumScroll, now().timeIntervalSince(lastScrollTime) < 0.08, speed > momentumMinSpeed {
                log?("momentum scroll")
                momRemX = 0; momRemY = 0
                scheduleMomentum()
            }
        case .pinch: break
        }
    }

    private func scheduleMomentum() {
        cancelMomentum = schedule(momentumTick) { [weak self] in self?.momentumTickFired() }
    }

    private func momentumTickFired() {
        velX *= momentumFriction; velY *= momentumFriction
        if hypot(velX, velY) < momentumStopSpeed { cancelMomentum = nil; return }
        momRemX += velX * momentumTick; momRemY += velY * momentumTick
        let ix = Int(momRemX.rounded(.towardZero)), iy = Int(momRemY.rounded(.towardZero))
        momRemX -= Double(ix); momRemY -= Double(iy)
        if ix != 0 || iy != 0 { sink.scroll(dx: ix, dy: iy) }
        scheduleMomentum()
    }

    private func stopMomentum() { cancelMomentum?(); cancelMomentum = nil }

    private func beginMulti(_ n: Int, _ c: CGPoint, _ s: CGFloat, _ cfg: TouchConfig) {
        endLongPress()
        let first = mode != .multi
        if first { fired = false }
        mode = .multi
        multiN = n; baseC = c; baseS = s
        if first, n == 3, cfg.windowThreeFingerDrag, let w = windows, let info = w.window(at: c) {
            dragWin = info; winDragC = c
            log?("window drag")
        }
    }

    private func finish(_ cfg: TouchConfig) {
        endLongPress()
        if mode == .pending {
            let maxClicks = cfg.tripleTapSelectLine ? 3 : 2
            var clicks = 1
            if now().timeIntervalSince(lastTapTime) < cfg.doubleTapWindow,
               Self.dist(lastTapPt, startPt) < doubleTapRadius { clicks = min(tapCount + 1, maxClicks) }
            tapCount = clicks
            lastTapTime = clicks >= maxClicks ? .distantPast : now()
            lastTapPt = startPt
            if clicks == 2, cfg.windowSnap, let w = windows, let info = w.window(at: startPt), info.titleBar.contains(startPt) {
                log?("title-bar double-tap: maximize")
                toggleMaximize(info, w)
                lastTapTime = .distantPast
            } else {
                var p = startPt
                if cfg.touchMagnet, let w = windows, let m = w.magnet(near: startPt, radius: CGFloat(cfg.magnetRadius)) {
                    p = m
                    if m != startPt { log?("magnet") }
                }
                log?("tap x\(clicks)")
                sink.mouse(.move, at: p, clicks: 1)
                sink.mouse(.leftDown, at: p, clicks: clicks)
                sink.mouse(.leftUp, at: p, clicks: clicks)
            }
        } else if mode == .held {
            log?("right-click")
            sink.mouse(.move, at: startPt, clicks: 1)
            sink.mouse(.rightDown, at: startPt, clicks: 1)
            sink.mouse(.rightUp, at: startPt, clicks: 1)
        } else if mode == .grab {
            endGrab()
        } else if mode == .dragging {
            sink.mouse(.leftUp, at: lastPt, clicks: 1)
            if let t = titleWin, let w = windows {
                w.showPreview(nil)
                if let r = Snap.rect(for: lastPt, in: w.usableBounds(containing: lastPt)) { w.setFrame(t.id, r); log?("snap window") }
            }
        } else if mode == .two {
            endTwo(cfg)
        } else if mode == .multi {
            endWinDrag()
        }
        titleWin = nil
        mode = .idle; fired = false; multiN = 0; edgeStart = nil
        scrollRemX = 0; scrollRemY = 0
    }

    private func toggleMaximize(_ info: WindowInfo, _ w: WindowService) {
        let usable = w.usableBounds(containing: info.frame.origin)
        let isMax = abs(info.frame.width - usable.width) < 4 && abs(info.frame.height - usable.height) < 4
        if isMax, let saved = restoreFrames.removeValue(forKey: info.id) { w.setFrame(info.id, saved) }
        else if !isMax { restoreFrames[info.id] = info.frame; w.setFrame(info.id, usable) }
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
        let t = now(), dt = t.timeIntervalSince(lastScrollTime)
        if dt > 0.002 {
            velX = 0.5 * velX + 0.5 * Double(dx) * k / dt
            velY = 0.5 * velY + 0.5 * Double(dy) * k / dt
            lastScrollTime = t
        }
        let ix = Int(scrollRemX.rounded(.towardZero)), iy = Int(scrollRemY.rounded(.towardZero))
        scrollRemX -= Double(ix); scrollRemY -= Double(iy)
        if ix != 0 || iy != 0 { sink.scroll(dx: ix, dy: iy) }
    }

    // MARK: - Three or more fingers: swipe / pinch

    private func handleMulti(_ c: CGPoint, _ s: CGFloat, _ W: CGFloat, _ cfg: TouchConfig) {
        if let w = dragWin, cfg.windowThreeFingerDrag, multiN == 3 {
            winDragC = c
            windows?.setFrame(w.id, w.frame.offsetBy(dx: c.x - baseC.x, dy: c.y - baseC.y))
            if cfg.windowSnap, let svc = windows { svc.showPreview(Snap.rect(for: c, in: svc.usableBounds(containing: c))) }
            return
        }
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
