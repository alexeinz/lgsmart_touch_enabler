import CoreGraphics
import Testing
@testable import TouchCore

@Suite struct TwoFingerGestureTests {
    private func rig(flick: Bool = false, zoom: Bool = false) -> Rig {
        let r = Rig { c in
            if flick {
                c.setShortcut(Shortcut(keyCode: 33, flags: .maskCommand), for: .swipe2Left)
                c.setShortcut(Shortcut(keyCode: 30, flags: .maskCommand), for: .swipe2Right)
            }
            if zoom { c.setShortcut(Shortcut(keyCode: 40, flags: .maskCommand), for: .smartZoom) }
        }
        r.engine.displayBounds = CGRect(x: 0, y: 0, width: Rig.width, height: 1700)
        return r
    }
    private func pair(_ x: CGFloat) -> [CGPoint] { Fixture.pair(CGPoint(x: x, y: 800), spread: 200) }

    @Test func fastTwoFingerFlickFiresBackForward() {
        let r = rig(flick: true)
        r.touch(pair(1500))
        for i in 1...6 { r.clock.advance(0.02); r.touch(pair(1500 - CGFloat(i) * 60)) }
        r.lift()
        #expect(r.sink.keys.last == 33)
    }

    @Test func slowTwoFingerScrollDoesNotFlick() {
        let r = rig(flick: true)
        r.touch(pair(1500))
        for i in 1...6 { r.clock.advance(0.2); r.touch(pair(1500 - CGFloat(i) * 60)) }
        r.lift()
        #expect(r.sink.keys.isEmpty)
    }

    @Test func flickIsOffByDefault() {
        let r = rig()
        r.touch(pair(1500))
        for i in 1...6 { r.clock.advance(0.02); r.touch(pair(1500 - CGFloat(i) * 60)) }
        r.lift()
        #expect(r.sink.keys.isEmpty)
    }

    @Test func twoFingerDoubleTapFiresSmartZoomWithoutRightClick() {
        let r = rig(zoom: true)
        r.touch(pair(1500)); r.clock.advance(0.05); r.lift()
        r.clock.advance(0.1)
        r.touch(pair(1500)); r.clock.advance(0.05); r.lift()
        r.clock.advance(1)
        #expect(r.sink.keys == [40])
        #expect(!r.sink.kinds.contains(.rightDown))
    }

    @Test func singleTwoFingerTapStillRightClicksAfterDelay() {
        let r = rig(zoom: true)
        r.touch(pair(1500)); r.clock.advance(0.05); r.lift()
        #expect(!r.sink.kinds.contains(.rightDown))
        r.clock.advance(1)
        #expect(r.sink.kinds.contains(.rightDown))
        #expect(r.sink.keys.isEmpty)
    }

    @Test func twoFingerTapRightClicksImmediatelyWhenSmartZoomOff() {
        let r = rig()
        r.touch(pair(1500)); r.clock.advance(0.05); r.lift()
        #expect(r.sink.kinds.contains(.rightDown))
    }
}
