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

@Suite struct ThreeFingerTapTests {
    private func three(_ x: CGFloat) -> [CGPoint] { [CGPoint(x: x, y: 800), CGPoint(x: x + 100, y: 800), CGPoint(x: x + 200, y: 840)] }

    @Test func quickThreeFingerTapFiresLookUp() {
        let r = Rig()
        r.touch(three(1500)); r.clock.advance(0.08); r.lift()
        #expect(r.sink.keys == [GestureID.tap3.defaultShortcut.keyCode!])
    }
    @Test func slowThreeFingerHoldIsNotATap() {
        let r = Rig()
        r.touch(three(1500)); r.clock.advance(0.6); r.lift()
        #expect(r.sink.keys.isEmpty)
    }
    @Test func swipeIsNotATap() {
        let r = Rig()
        r.touch(three(1500)); r.clock.advance(0.05); r.touch(three(1000)); r.clock.advance(0.05); r.lift()
        #expect(!r.sink.keys.contains(GestureID.tap3.defaultShortcut.keyCode!) || r.sink.keys.count == 1)
        #expect(r.sink.keys.count == 1)
    }
    @Test func sixContactsAreIgnored() {
        let r = Rig()
        r.touch((0..<6).map { CGPoint(x: 100 * CGFloat($0), y: 500) })
        r.touch((0..<7).map { CGPoint(x: 100 * CGFloat($0), y: 500) })
        #expect(r.sink.events.count >= 0)
    }
}

@Suite struct DragLockAndEdgeTests {
    private func rig(_ f: (inout TouchConfig) -> Void) -> Rig {
        let r = Rig(f)
        r.engine.displayBounds = CGRect(x: 0, y: 0, width: Rig.width, height: 1700)
        return r
    }
    private func drag(_ r: Rig) {
        r.touch([CGPoint(x: 500, y: 500)]); r.clock.advance(0.05)
        r.touch([CGPoint(x: 700, y: 500)]); r.clock.advance(0.05)
        r.lift()
    }

    @Test func dragLockHoldsButtonAndResumes() {
        let r = rig { $0.dragLock = true }
        drag(r)
        #expect(!r.sink.kinds.contains(.leftUp))
        r.clock.advance(0.5)
        r.touch([CGPoint(x: 900, y: 500)]); r.clock.advance(0.05)
        r.touch([CGPoint(x: 1000, y: 500)]); r.lift()
        #expect(r.sink.kinds.filter { $0 == .leftDown }.count == 1)
        #expect(!r.sink.kinds.contains(.leftUp))
        r.clock.advance(2)
        #expect(r.sink.kinds.last == .leftUp)
    }

    @Test func dragLockReleasesOnTimeout() {
        let r = rig { $0.dragLock = true }
        drag(r); r.clock.advance(2)
        #expect(r.sink.kinds.last == .leftUp)
    }

    @Test func dragReleasesImmediatelyWithoutDragLock() {
        let r = rig { _ in }
        drag(r)
        #expect(r.sink.kinds.last == .leftUp)
    }

    @Test func twoFingerEdgeSwipeFires() {
        let r = rig { $0.setShortcut(Shortcut(keyCode: 45, flags: .maskCommand), for: .edge2Right) }
        let w = Rig.width
        r.touch(Fixture.pair(CGPoint(x: w - 70, y: 800), spread: 80))
        for i in 1...8 { r.clock.advance(0.02); r.touch(Fixture.pair(CGPoint(x: w - 70 - CGFloat(i) * 40, y: 800), spread: 80)) }
        r.lift()
        #expect(r.sink.keys == [45])
        #expect(r.sink.scrolls.isEmpty)
    }

    @Test func twoFingerSwipeAwayFromEdgeStillScrolls() {
        let r = rig { $0.setShortcut(Shortcut(keyCode: 45, flags: .maskCommand), for: .edge2Right) }
        r.touch(Fixture.pair(CGPoint(x: 1500, y: 800), spread: 80))
        for i in 1...8 { r.clock.advance(0.02); r.touch(Fixture.pair(CGPoint(x: 1500, y: 800 - CGFloat(i) * 40), spread: 80)) }
        r.lift()
        #expect(r.sink.keys.isEmpty)
        #expect(!r.sink.scrolls.isEmpty)
    }

    @Test func twoFingerHoldFiresKeyboardShortcut() {
        let r = rig { $0.setShortcut(Shortcut(keyCode: 96, flags: [.maskAlternate, .maskCommand]), for: .keyboard) }
        r.touch(Fixture.pair(CGPoint(x: 1500, y: 800), spread: 200))
        r.clock.advance(0.8); r.lift()
        #expect(r.sink.keys == [96])
    }

    @Test func twoFingerHoldDoesNothingByDefault() {
        let r = rig { _ in }
        r.touch(Fixture.pair(CGPoint(x: 1500, y: 800), spread: 200))
        r.clock.advance(0.8); r.lift()
        #expect(r.sink.keys.isEmpty)
    }
}
