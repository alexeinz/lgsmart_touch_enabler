import CoreGraphics
import Testing
@testable import TouchCore

@Suite struct GestureEngineTests {
    @Test func tapProducesClick() {
        let r = Rig()
        r.touch([CGPoint(x: 500, y: 500)])
        r.clock.advance(0.05)
        r.lift()
        #expect(r.sink.kinds.contains(.leftDown))
        #expect(r.sink.kinds.contains(.leftUp))
        #expect(r.sink.kinds.firstIndex(of: .leftDown)! < r.sink.kinds.lastIndex(of: .leftUp)!)
    }

    @Test func dragMovesWithLeftDrag() {
        let r = Rig()
        r.touch([CGPoint(x: 500, y: 500)])
        for i in 1...10 { r.touch([CGPoint(x: 500 + CGFloat(i) * 20, y: 500)]); r.clock.advance(0.01) }
        r.lift()
        #expect(r.sink.kinds.contains(.leftDrag))
        #expect(r.sink.kinds.last == .leftUp)
    }

    @Test func tinyJitterStaysATap() {
        let r = Rig()
        r.touch([CGPoint(x: 500, y: 500)])
        r.touch([CGPoint(x: 503, y: 502)])
        r.lift()
        #expect(!r.sink.kinds.contains(.leftDrag))
    }

    @Test func holdBecomesRightClick() {
        let r = Rig()
        r.touch([CGPoint(x: 500, y: 500)])
        r.clock.advance(0.7)
        r.lift()
        #expect(r.sink.kinds.contains(.rightDown))
        #expect(r.sink.kinds.contains(.rightUp))
    }

    @Test func holdDoesNothingWhenRightClickDisabled() {
        let r = Rig { $0.rightClickOnHold = false }
        r.touch([CGPoint(x: 500, y: 500)])
        r.clock.advance(1.0)
        r.lift()
        #expect(!r.sink.kinds.contains(.rightDown))
    }

    @Test func secondQuickTapIsDoubleClick() {
        let r = Rig()
        for _ in 0..<2 {
            r.touch([CGPoint(x: 500, y: 500)]); r.clock.advance(0.05); r.lift(); r.clock.advance(0.1)
        }
        let counts: [Int] = r.sink.events.compactMap { if case .mouse(.leftDown, _, let c) = $0 { return c } else { return nil } }
        #expect(counts == [1, 2])
    }

    @Test func slowSecondTapIsSingleClick() {
        let r = Rig()
        r.touch([CGPoint(x: 500, y: 500)]); r.clock.advance(0.05); r.lift(); r.clock.advance(1.0)
        r.touch([CGPoint(x: 500, y: 500)]); r.clock.advance(0.05); r.lift()
        let counts: [Int] = r.sink.events.compactMap { if case .mouse(.leftDown, _, let c) = $0 { return c } else { return nil } }
        #expect(counts == [1, 1])
    }

    @Test func twoFingerParallelMoveScrolls() {
        let r = Rig()
        r.touch([CGPoint(x: 500, y: 500), CGPoint(x: 600, y: 500)])
        for i in 1...10 {
            let dy = CGFloat(i) * 15
            r.touch([CGPoint(x: 500, y: 500 + dy), CGPoint(x: 600, y: 500 + dy)])
        }
        r.lift()
        #expect(!r.sink.scrolls.isEmpty)
        #expect(r.sink.scrolls.reduce(0) { $0 + $1.1 } != 0)
    }

    @Test func invertScrollFlipsDirection() {
        func total(invert: Bool) -> Int {
            let r = Rig { $0.invertScroll = invert }
            r.touch([CGPoint(x: 500, y: 500), CGPoint(x: 600, y: 500)])
            for i in 1...10 {
                let dy = CGFloat(i) * 15
                r.touch([CGPoint(x: 500, y: 500 + dy), CGPoint(x: 600, y: 500 + dy)])
            }
            return r.sink.scrolls.reduce(0) { $0 + $1.1 }
        }
        let a = total(invert: false), b = total(invert: true)
        #expect(a != 0)
        #expect(a == -b)
    }

    @Test func scrollSpeedScalesOutput() {
        func total(speed: Double) -> Int {
            let r = Rig { $0.scrollSpeed = speed }
            r.touch([CGPoint(x: 500, y: 500), CGPoint(x: 600, y: 500)])
            for i in 1...10 {
                let dy = CGFloat(i) * 15
                r.touch([CGPoint(x: 500, y: 500 + dy), CGPoint(x: 600, y: 500 + dy)])
            }
            return abs(r.sink.scrolls.reduce(0) { $0 + $1.1 })
        }
        #expect(total(speed: 2) > total(speed: 1))
    }

    @Test func twoFingerSpreadFiresZoomIn() {
        let r = Rig()
        r.touch([CGPoint(x: 1000, y: 500), CGPoint(x: 1100, y: 500)])
        for i in 1...15 {
            let d = CGFloat(i) * 15
            r.touch([CGPoint(x: 1000 - d, y: 500), CGPoint(x: 1100 + d, y: 500)])
        }
        r.lift()
        #expect(r.sink.keys.contains(Shortcut.kEqual))
        #expect(!r.sink.keys.contains(Shortcut.kMinus))
    }

    @Test func twoFingerPinchFiresZoomOut() {
        let r = Rig()
        r.touch([CGPoint(x: 800, y: 500), CGPoint(x: 1400, y: 500)])
        for i in 1...15 {
            let d = CGFloat(i) * 15
            r.touch([CGPoint(x: 800 + d, y: 500), CGPoint(x: 1400 - d, y: 500)])
        }
        r.lift()
        #expect(r.sink.keys.contains(Shortcut.kMinus))
    }

    @Test func threeFingerSwipeLeftFiresOnceBoundShortcut() {
        let r = Rig()
        let base = [CGPoint(x: 1500, y: 500), CGPoint(x: 1560, y: 520), CGPoint(x: 1620, y: 500)]
        r.touch(base)
        for step in 1...10 {
            r.touch(base.map { CGPoint(x: $0.x - CGFloat(step) * 40, y: $0.y) })
        }
        r.lift()
        let expected = GestureID.swipe3Left.defaultShortcut.keyCode!
        #expect(r.sink.keys.filter { $0 == expected }.count == 1)
    }

    @Test func customBindingIsUsed() {
        let custom = Shortcut(keyCode: 0, flags: .maskCommand)
        let r = Rig { $0.setShortcut(custom, for: .swipe3Left) }
        let base = [CGPoint(x: 1500, y: 500), CGPoint(x: 1560, y: 520), CGPoint(x: 1620, y: 500)]
        r.touch(base)
        for step in 1...10 { r.touch(base.map { CGPoint(x: $0.x - CGFloat(step) * 40, y: $0.y) }) }
        r.lift()
        #expect(r.sink.events.contains(.key(0, CGEventFlags.maskCommand.rawValue)))
    }

    @Test func disabledBindingFiresNothing() {
        let r = Rig { $0.setShortcut(.disabled, for: .swipe3Left) }
        let base = [CGPoint(x: 1500, y: 500), CGPoint(x: 1560, y: 520), CGPoint(x: 1620, y: 500)]
        r.touch(base)
        for step in 1...10 { r.touch(base.map { CGPoint(x: $0.x - CGFloat(step) * 40, y: $0.y) }) }
        r.lift()
        #expect(r.sink.keys.isEmpty)
    }

    @Test func gesturesDisabledSuppressesMultiFinger() {
        let r = Rig { $0.gesturesEnabled = false }
        let base = [CGPoint(x: 1500, y: 500), CGPoint(x: 1560, y: 520), CGPoint(x: 1620, y: 500)]
        r.touch(base)
        for step in 1...10 { r.touch(base.map { CGPoint(x: $0.x - CGFloat(step) * 40, y: $0.y) }) }
        r.lift()
        #expect(r.sink.keys.isEmpty)
    }
}

@Suite struct EdgeSwipeTests {
    static let bounds = CGRect(x: 0, y: 0, width: 3000, height: 1700)

    private func rig(_ id: GestureID? = .edgeLeft) -> Rig {
        let r = Rig { cfg in if let id { cfg.setShortcut(Shortcut(keyCode: 0x7B, flags: .maskControl), for: id) } }
        r.engine.displayBounds = Self.bounds
        return r
    }

    @Test func leftEdgeSwipeFiresBoundShortcutAndNoClick() {
        let r = rig(.edgeLeft)
        r.touch([CGPoint(x: 10, y: 800)])
        for i in 1...10 { r.touch([CGPoint(x: 10 + CGFloat(i) * 30, y: 800)]) }
        r.lift()
        #expect(r.sink.keys == [0x7B])
        #expect(r.sink.kinds.isEmpty)
    }

    @Test func edgeSwipesAreDisabledByDefault() {
        let r = rig(nil)
        r.touch([CGPoint(x: 10, y: 800)])
        for i in 1...10 { r.touch([CGPoint(x: 10 + CGFloat(i) * 30, y: 800)]) }
        r.lift()
        #expect(r.sink.keys.isEmpty)
        #expect(r.sink.kinds.contains(.leftDrag))
    }

    @Test func rightEdgeNeedsInwardMotion() {
        let r = rig(.edgeRight)
        r.touch([CGPoint(x: 2990, y: 800)])
        for i in 1...10 { r.touch([CGPoint(x: 2990 - CGFloat(i) * 30, y: 800)]) }
        r.lift()
        #expect(r.sink.keys == [0x7B])
    }

    @Test func dragAlongTheEdgeStaysADrag() {
        let r = rig(.edgeLeft)
        r.touch([CGPoint(x: 10, y: 800)])
        for i in 1...10 { r.touch([CGPoint(x: 10, y: 800 + CGFloat(i) * 30)]) }
        r.lift()
        #expect(r.sink.keys.isEmpty)
        #expect(r.sink.kinds.contains(.leftDrag))
    }

    @Test func tapInEdgeZoneStillClicks() {
        let r = rig(.edgeLeft)
        r.touch([CGPoint(x: 10, y: 800)])
        r.lift()
        #expect(r.sink.kinds.contains(.leftDown))
        #expect(r.sink.keys.isEmpty)
    }

    @Test func touchOutsideZoneIsNormalDrag() {
        let r = rig(.edgeLeft)
        r.touch([CGPoint(x: 500, y: 800)])
        for i in 1...10 { r.touch([CGPoint(x: 500 + CGFloat(i) * 30, y: 800)]) }
        r.lift()
        #expect(r.sink.keys.isEmpty)
        #expect(r.sink.kinds.contains(.leftDrag))
    }
}
