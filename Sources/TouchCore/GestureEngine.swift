import CoreGraphics
import Foundation

public enum MouseEventKind: Sendable { case move, leftDown, leftUp, leftDrag, rightDown, rightUp }

/// Where the engine sends synthesized input. The real implementation posts CGEvents; tests record.
public protocol EventSink: AnyObject {
    func mouse(_ kind: MouseEventKind, at p: CGPoint, clicks: Int)
    func scroll(dx: Int, dy: Int)
    func key(_ code: UInt16, flags: CGEventFlags)
    /// Trackpad-style zoom. `delta` is the relative size change since the last event (additive).
    func magnify(_ delta: Double, phase: GesturePhase)
    /// Trackpad-style rotation in degrees since the last event, counter-clockwise positive.
    func rotate(_ degrees: Double, phase: GesturePhase)
    /// Spaces / Mission Control swipe that follows the fingers. `progress` is the total travel since
    /// the gesture began (1 = one full swipe); `velocity` (progress per second) matters on `.ended`.
    func dockSwipe(_ axis: SwipeAxis, progress: Double, velocity: Double, phase: GesturePhase)
}

/// Raw values are the phase codes macOS uses in gesture events.
public enum GesturePhase: Int, Sendable { case began = 1, changed = 2, ended = 4 }
public enum SwipeAxis: Int, Sendable { case horizontal = 1, vertical = 2 }

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
    private var cancelPendingRightClick: Cancel?   // right-click deferred so a second two-finger tap can become smart zoom
    private var lastTwoTapTime = Date.distantPast
    private var lastTwoTapPt = CGPoint.zero
    private var momRemX = 0.0, momRemY = 0.0
    private var tapCount = 0
    private var grabCandidate: (win: WindowInfo, edges: GrabEdges)?
    private var grab: (win: WindowInfo, edges: GrabEdges)?
    private var cancelGrab: Cancel?
    private var titleWin: WindowInfo?             // window whose title bar the current one-finger drag started on
    private var dragWin: WindowInfo?              // window being moved by three fingers
    private var winDragC = CGPoint.zero
    private var restoreFrames: [Int: CGRect] = [:]
    private var baseAngle = 0.0                   // two-finger angle (degrees) at gesture start
    private var lastAngle = 0.0
    private var lastS: CGFloat = 0                // spread at the last native magnify event
    private var nativePinch = false               // a native magnify stream is open
    private var rotating = false                  // a native rotate stream is open
    private var rotAccum = 0.0                    // rotation seen before the rotate stream opens
    private var swipeAxis: SwipeAxis?             // set while a native dock swipe is open
    private var swipeProgress = 0.0
    private var swipeVel = 0.0
    private var lastSwipeTime = Date.distantPast

    // Fixed geometry, relative to display width.
    private let scrollStart: CGFloat = 0.006
    private let pinchStart: CGFloat = 0.010
    private let multiPinchIn: CGFloat = 0.7
    private let multiPinchOut: CGFloat = 1.4
    private let rotateStart = 4.0                 // degrees of twist that count as a deliberate rotation
    private let rotateStreamStart = 5.0           // degrees before rotate events start during a pinch
    private let swipeLock: CGFloat = 0.02         // travel that locks a native swipe to an axis
    private let doubleTapRadius: CGFloat = 30
    private let twoTapMaxDuration: TimeInterval = 0.3
    private let flickMaxDuration: TimeInterval = 0.4   // a two-finger flick (back/forward) must be this quick
    private let flickDistance: CGFloat = 0.08          // and travel this fraction of the display width
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
            else if n == 2 { beginTwo(pts, c, s) }
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
            } else if n == 2 { beginTwo(pts, c, s) }
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
            } else if n == 2 { beginTwo(pts, c, s) }
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
            if n == 2 { handleTwo(pts, c, s, W, cfg) }
            else if n >= 3 { endNativePinch(); beginMulti(n, c, s, cfg) }
            else { endTwo(cfg); mode = .consumed }

        case .multi:
            if n == multiN { handleMulti(c, s, W, cfg) }
            else if n >= 3 { endSwipe(); multiN = n; baseC = c; baseS = s; if n != 3 { endWinDrag() } }   // finger count changed: re-baseline
            else { endSwipe(); endWinDrag(); mode = .consumed }

        case .consumed:
            break
        }
    }

    /// Release anything held (e.g. a drag in progress). Call when disabling or shutting down.
    public func reset() {
        endLongPress()
        cancelPendingRightClick?(); cancelPendingRightClick = nil
        stopMomentum()
        if mode == .dragging { sink.mouse(.leftUp, at: lastPt, clicks: 1) }
        endGrab(); titleWin = nil; windows?.showPreview(nil)
        dragWin = nil
        endNativePinch(); endSwipe()
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

    private func beginTwo(_ pts: [CGPoint], _ c: CGPoint, _ s: CGFloat) {
        endLongPress()
        mode = .two; twoMode = .undecided
        baseC = c; baseS = s; refS = s; lastC = c
        baseAngle = Self.angle(pts); lastAngle = baseAngle; rotAccum = 0
        twoStart = now(); lastScrollTime = twoStart; velX = 0; velY = 0
    }

    /// Called when a two-finger gesture ends (a finger lifted). Handles two-finger tap and flick momentum.
    private func endTwo(_ cfg: TouchConfig) {
        endNativePinch()
        switch twoMode {
        case .undecided:
            guard now().timeIntervalSince(twoStart) < twoTapMaxDuration else { break }
            let zoomOn = cfg.gesturesEnabled && !cfg.shortcut(for: .smartZoom).isDisabled
            if zoomOn, cancelPendingRightClick != nil,
               now().timeIntervalSince(lastTwoTapTime) < cfg.doubleTapWindow,
               Self.dist(lastTwoTapPt, baseC) < doubleTapRadius * 2 {
                cancelPendingRightClick?(); cancelPendingRightClick = nil
                lastTwoTapTime = .distantPast
                log?("two-finger double-tap: smart zoom")
                sink.mouse(.move, at: baseC, clicks: 1)
                fire(.smartZoom, cfg)
            } else if cfg.twoFingerTapRightClick {
                let p = baseC
                let rightClick = { [weak self] in
                    guard let self else { return }
                    self.cancelPendingRightClick = nil
                    self.log?("two-finger tap: right-click")
                    self.sink.mouse(.move, at: p, clicks: 1)
                    self.sink.mouse(.rightDown, at: p, clicks: 1)
                    self.sink.mouse(.rightUp, at: p, clicks: 1)
                }
                if zoomOn {   // wait out the double-tap window before committing to a right-click
                    cancelPendingRightClick?()
                    lastTwoTapTime = now(); lastTwoTapPt = p
                    cancelPendingRightClick = schedule(cfg.doubleTapWindow, rightClick)
                } else { rightClick() }
            }
        case .scroll:
            if cfg.gesturesEnabled, let id = flick(cfg) {
                log?("two-finger flick")
                fire(id, cfg)
                break
            }
            let speed = hypot(velX, velY)
            if cfg.momentumScroll, now().timeIntervalSince(lastScrollTime) < 0.08, speed > momentumMinSpeed {
                log?("momentum scroll")
                momRemX = 0; momRemY = 0
                scheduleMomentum()
            }
        case .pinch: break
        }
    }

    /// A quick, mostly horizontal two-finger stroke that lifted while still moving, if one is bound.
    private func flick(_ cfg: TouchConfig) -> GestureID? {
        let dx = lastC.x - baseC.x, dy = lastC.y - baseC.y
        guard now().timeIntervalSince(twoStart) < flickMaxDuration,
              abs(dx) > flickDistance * displayBounds.width, abs(dx) > 2 * abs(dy) else { return nil }
        let id: GestureID = dx < 0 ? .swipe2Left : .swipe2Right
        return cfg.shortcut(for: id).isDisabled ? nil : id
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
            endSwipe()
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

    private func handleTwo(_ pts: [CGPoint], _ c: CGPoint, _ s: CGFloat, _ W: CGFloat, _ cfg: TouchConfig) {
        let angle = Self.angle(pts)
        switch twoMode {
        case .undecided:
            let dc = Self.dist(c, baseC), ds = abs(s - baseS)
            let native = cfg.gesturesEnabled && cfg.nativeGestures
            // A twist: the fingers turn around their midpoint further than the midpoint travels.
            let twist = abs(Self.wrapDegrees(angle - baseAngle))
            let arc = CGFloat(twist * .pi / 180) * s
            let rotated = native && twist > rotateStart && arc > pinchStart * W && arc > dc
            if (cfg.gesturesEnabled && ds > pinchStart * W && ds > dc) || rotated {
                twoMode = .pinch; refS = s
                if native {
                    log?("native pinch")
                    nativePinch = true; lastS = s      // lastAngle stays at the start so the twist so far counts
                    sink.mouse(.move, at: c, clicks: 1)   // gesture events go to the window under the pointer
                    sink.magnify(0, phase: .began)
                }
            } else if dc > scrollStart * W {
                twoMode = .scroll; lastC = baseC
                emitScroll(c.x - lastC.x, c.y - lastC.y, cfg); lastC = c
            }
        case .scroll:
            emitScroll(c.x - lastC.x, c.y - lastC.y, cfg); lastC = c
        case .pinch where nativePinch:
            if s != lastS {
                sink.magnify(Double(s / max(lastS, 1)) - 1, phase: .changed)
                lastS = s
            }
            let d = Self.wrapDegrees(angle - lastAngle)
            lastAngle = angle
            // Screen y points down, so a positive angle change is clockwise; NSEvent wants the opposite.
            if rotating {
                if d != 0 { sink.rotate(-d, phase: .changed) }
            } else {
                rotAccum += d
                if abs(rotAccum) > rotateStreamStart {
                    rotating = true
                    sink.rotate(0, phase: .began)
                    sink.rotate(-rotAccum, phase: .changed)
                }
            }
        case .pinch:
            let r = s / max(refS, 1)
            let step = CGFloat(cfg.zoomStep)
            if r > step { log?("zoom in"); fire(.pinch2Out, cfg); refS = s }
            else if r < 1 / step { log?("zoom out"); fire(.pinch2In, cfg); refS = s }
        }
    }

    /// Closes any open native magnify / rotate stream.
    private func endNativePinch() {
        if rotating { sink.rotate(0, phase: .ended); rotating = false }
        if nativePinch { sink.magnify(0, phase: .ended); nativePinch = false }
        rotAccum = 0
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
        guard cfg.gesturesEnabled, (3...5).contains(multiN) else { return }
        let dx = c.x - baseC.x, dy = c.y - baseC.y
        if let axis = swipeAxis { updateSwipe(axis, dx, dy, W); return }
        guard !fired else { return }
        let travel = max(abs(dx), abs(dy))
        if cfg.nativeSwipes {
            // Follow the fingers instead of firing a shortcut once.
            if travel > swipeLock * W, travel > abs(s - baseS) {
                fired = true
                let axis: SwipeAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
                log?("native swipe \(axis == .horizontal ? "horizontal" : "vertical")")
                swipeAxis = axis; swipeProgress = 0; swipeVel = 0; lastSwipeTime = now()
                baseC = c                           // progress counts from the lock point
                sink.dockSwipe(axis, progress: 0, velocity: 0, phase: .began)
                return
            }
        } else if travel > CGFloat(cfg.swipeDistance) * W {
            fired = true
            let ids = GestureID.swipeIDs[multiN]!   // [left, right, up, down]
            let id: GestureID
            if abs(dx) > abs(dy) { id = dx < 0 ? ids[0] : ids[1] }
            else { id = dy < 0 ? ids[2] : ids[3] }
            log?("\(id.rawValue)")
            fire(id, cfg)
            return
        }
        if multiN >= 4 {
            let r = s / max(baseS, 1)
            if r < multiPinchIn { fired = true; log?("pinch4In"); fire(.pinch4In, cfg) }
            else if r > multiPinchOut { fired = true; log?("pinch4Out"); fire(.pinch4Out, cfg) }
        }
    }

    /// Fingers moving left or up count as positive progress (next Space / Mission Control).
    private func updateSwipe(_ axis: SwipeAxis, _ dx: CGFloat, _ dy: CGFloat, _ W: CGFloat) {
        let h = displayBounds.height > 0 ? displayBounds.height : W
        let p = axis == .horizontal ? Double(-dx / max(W, 1)) : Double(-dy / max(h, 1))
        let t = now(), dt = t.timeIntervalSince(lastSwipeTime)
        if dt > 0.002 {
            swipeVel = 0.5 * swipeVel + 0.5 * (p - swipeProgress) / dt
            lastSwipeTime = t
        }
        guard p != swipeProgress else { return }
        swipeProgress = p
        sink.dockSwipe(axis, progress: p, velocity: swipeVel, phase: .changed)
    }

    private func endSwipe() {
        guard let axis = swipeAxis else { return }
        swipeAxis = nil
        // A finger that rested before lifting is not a flick.
        let v = now().timeIntervalSince(lastSwipeTime) < 0.1 ? swipeVel : 0
        sink.dockSwipe(axis, progress: swipeProgress, velocity: v, phase: .ended)
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

    /// Direction from the first to the second point, in degrees. 0 with fewer than two points.
    static func angle(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 2 else { return 0 }
        return Double(atan2(pts[1].y - pts[0].y, pts[1].x - pts[0].x)) * 180 / .pi
    }

    /// Wraps an angle difference into (-90, 90], so the two fingers swapping order reads as no turn.
    static func wrapDegrees(_ d: Double) -> Double {
        var r = d.truncatingRemainder(dividingBy: 180)
        if r > 90 { r -= 180 } else if r <= -90 { r += 180 }
        return r
    }

    static func spread(_ pts: [CGPoint], _ c: CGPoint) -> CGFloat {
        pts.map { dist($0, c) }.reduce(0, +) / CGFloat(pts.count)
    }
}
