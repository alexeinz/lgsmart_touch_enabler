import CoreGraphics
import Testing
@testable import TouchCore

final class FakeWindows: WindowService {
    var win = WindowInfo(id: 1, frame: CGRect(x: 500, y: 300, width: 800, height: 600),
                         titleBar: CGRect(x: 500, y: 300, width: 800, height: 28))
    var usable = CGRect(x: 0, y: 25, width: 3000, height: 1600)
    var magnetTarget: CGPoint?
    var frames: [CGRect] = []
    var previews: [CGRect?] = []
    var handles: [CGRect?] = []
    func window(at p: CGPoint) -> WindowInfo? { win.frame.insetBy(dx: -30, dy: -30).contains(p) ? win : nil }
    func setFrame(_ id: Int, _ frame: CGRect) { frames.append(frame); win.frame = frame }
    func usableBounds(containing p: CGPoint) -> CGRect { usable }
    func magnet(near p: CGPoint, radius: CGFloat) -> CGPoint? { magnetTarget }
    func showHandle(_ rect: CGRect?) { handles.append(rect) }
    func showPreview(_ rect: CGRect?) { previews.append(rect) }
}

@Suite struct GeometryTests {
    let f = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test func edgesDetected() {
        #expect(GrabEdges.at(CGPoint(x: 500, y: 250), in: f, zone: 24) == .right)
        #expect(GrabEdges.at(CGPoint(x: 300, y: 400), in: f, zone: 24) == .bottom)
        #expect(GrabEdges.at(CGPoint(x: 500, y: 400), in: f, zone: 24) == [.right, .bottom])
        #expect(GrabEdges.at(CGPoint(x: 300, y: 250), in: f, zone: 24).isEmpty)
    }

    @Test func topAloneIsTitleBarButTopCornerGrabs() {
        #expect(GrabEdges.at(CGPoint(x: 300, y: 100), in: f, zone: 24).isEmpty)
        #expect(GrabEdges.at(CGPoint(x: 100, y: 100), in: f, zone: 24) == [.left, .top])
    }

    @Test func resizeMovesGrabbedEdgesAndKeepsMinimum() {
        let r = GrabEdges([.right, .bottom]).resize(f, dx: 50, dy: -20)
        #expect(r == CGRect(x: 100, y: 100, width: 450, height: 280))
        let l = GrabEdges.left.resize(f, dx: 1000, dy: 0)
        #expect(l.width == 160 && l.maxX == f.maxX)
    }

    @Test func snapZones() {
        let b = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(Snap.rect(for: CGPoint(x: 5, y: 400), in: b) == CGRect(x: 0, y: 0, width: 500, height: 800))
        #expect(Snap.rect(for: CGPoint(x: 995, y: 400), in: b) == CGRect(x: 500, y: 0, width: 500, height: 800))
        #expect(Snap.rect(for: CGPoint(x: 5, y: 5), in: b) == CGRect(x: 0, y: 0, width: 500, height: 400))
        #expect(Snap.rect(for: CGPoint(x: 995, y: 795), in: b) == CGRect(x: 500, y: 400, width: 500, height: 400))
        #expect(Snap.rect(for: CGPoint(x: 500, y: 5), in: b) == b)
        #expect(Snap.rect(for: CGPoint(x: 500, y: 400), in: b) == nil)
    }
}

@Suite struct WindowHelperTests {
    func rig(_ c: @escaping (inout TouchConfig) -> Void = { _ in }) -> (Rig, FakeWindows) {
        let r = Rig(c); let w = FakeWindows(); r.engine.windows = w; return (r, w)
    }

    @Test func edgeGrabResizesAfterHold() {
        let (r, w) = rig { $0.windowEdgeGrab = true; $0.rightClickOnHold = true }
        let start = CGPoint(x: 1300, y: 600)                    // on the right edge
        r.touch([start])
        r.clock.advance(0.3)
        #expect(w.handles.last! != nil)
        r.touch([CGPoint(x: 1400, y: 600)])
        r.lift()
        #expect(w.frames.last?.width == 900)
        #expect(!r.sink.kinds.contains(.leftDown) && !r.sink.kinds.contains(.rightDown))
        #expect(w.handles.last! == nil)
    }

    @Test func edgeGrabOffByDefault() {
        let (r, w) = rig()
        r.touch([CGPoint(x: 1300, y: 600)]); r.clock.advance(0.3)
        r.lift()
        #expect(w.frames.isEmpty)
    }

    @Test func movingBeforeHoldIsNormalDragNotGrab() {
        let (r, w) = rig { $0.windowEdgeGrab = true }
        r.touch([CGPoint(x: 1300, y: 600)])
        r.touch([CGPoint(x: 1500, y: 600)])
        r.lift()
        #expect(w.frames.isEmpty)
        #expect(r.sink.kinds.contains(.leftDown))
    }

    @Test func threeFingerDragMovesWindow() {
        let (r, w) = rig { $0.windowThreeFingerDrag = true; $0.windowSnap = false }
        let a = [CGPoint(x: 800, y: 600), CGPoint(x: 850, y: 600), CGPoint(x: 900, y: 600)]
        r.touch(a)
        r.touch(a.map { CGPoint(x: $0.x + 100, y: $0.y + 50) })
        r.lift()
        #expect(w.frames.last?.origin == CGPoint(x: 600, y: 350))
        #expect(r.sink.keys.isEmpty)
    }

    @Test func threeFingerDragToEdgeSnaps() {
        let (r, w) = rig { $0.windowThreeFingerDrag = true }
        let a = [CGPoint(x: 800, y: 600), CGPoint(x: 850, y: 600), CGPoint(x: 900, y: 600)]
        r.touch(a)
        r.touch([CGPoint(x: 5, y: 600), CGPoint(x: 10, y: 600), CGPoint(x: 15, y: 600)])
        #expect(w.previews.last! == CGRect(x: 0, y: 25, width: 1500, height: 1600))
        r.lift()
        #expect(w.frames.last == CGRect(x: 0, y: 25, width: 1500, height: 1600))
        #expect(w.previews.last! == nil)
    }

    @Test func titleBarDragToEdgeSnaps() {
        let (r, w) = rig()
        r.touch([CGPoint(x: 900, y: 310)])
        r.touch([CGPoint(x: 600, y: 310)])
        r.touch([CGPoint(x: 5, y: 600)])
        #expect(w.previews.last! != nil)
        r.lift()
        #expect(w.frames.last == CGRect(x: 0, y: 25, width: 1500, height: 1600))
    }

    @Test func titleBarDoubleTapMaximizesThenRestores() {
        let (r, w) = rig()
        let p = CGPoint(x: 900, y: 310)
        let orig = w.win.frame
        for _ in 0..<2 { r.touch([p]); r.clock.advance(0.05); r.lift(); r.clock.advance(0.1) }
        #expect(w.frames.last == w.usable)
        for _ in 0..<2 { r.touch([p]); r.clock.advance(0.05); r.lift(); r.clock.advance(0.1) }
        #expect(w.frames.last == orig)
    }

    @Test func magnetRedirectsTap() {
        let (r, w) = rig()
        w.magnetTarget = CGPoint(x: 1000, y: 700)
        r.touch([CGPoint(x: 1005, y: 705)]); r.lift()
        #expect(r.sink.events.contains(.mouse(.leftDown, CGPoint(x: 1000, y: 700), 1)))
    }

    @Test func magnetCanBeDisabled() {
        let (r, w) = rig { $0.touchMagnet = false }
        w.magnetTarget = CGPoint(x: 1000, y: 700)
        r.touch([CGPoint(x: 1005, y: 705)]); r.lift()
        #expect(r.sink.events.contains(.mouse(.leftDown, CGPoint(x: 1005, y: 705), 1)))
    }

    @Test func tripleTapSendsThreeClicks() {
        let r = Rig()
        let p = CGPoint(x: 2000, y: 900)
        for _ in 0..<3 { r.touch([p]); r.clock.advance(0.05); r.lift(); r.clock.advance(0.1) }
        let counts = r.sink.events.compactMap { e -> Int? in if case .mouse(.leftDown, _, let c) = e { return c } else { return nil } }
        #expect(counts == [1, 2, 3])
    }

    @Test func tripleTapCanBeDisabled() {
        let r = Rig { $0.tripleTapSelectLine = false }
        let p = CGPoint(x: 2000, y: 900)
        for _ in 0..<3 { r.touch([p]); r.clock.advance(0.05); r.lift(); r.clock.advance(0.1) }
        let counts = r.sink.events.compactMap { e -> Int? in if case .mouse(.leftDown, _, let c) = e { return c } else { return nil } }
        #expect(counts == [1, 2, 1])
    }

    @Test func holdThenDragSelectsWord() {
        let r = Rig { $0.holdToSelect = true }
        r.touch([CGPoint(x: 2000, y: 900)])
        r.clock.advance(0.7)
        #expect(!r.sink.kinds.contains(.rightDown))
        r.touch([CGPoint(x: 2200, y: 900)])
        r.lift()
        #expect(r.sink.events.contains(.mouse(.leftDown, CGPoint(x: 2000, y: 900), 2)))
        #expect(r.sink.kinds.contains(.leftUp))
    }

    @Test func holdWithoutMovingStillRightClicksInSelectMode() {
        let r = Rig { $0.holdToSelect = true }
        r.touch([CGPoint(x: 2000, y: 900)])
        r.clock.advance(0.7)
        r.lift()
        #expect(r.sink.kinds.contains(.rightDown))
    }
}
