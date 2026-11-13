import CoreGraphics
import Testing
@testable import TouchCore

private let mid = CGPoint(x: 1500, y: 800)

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) < tol }

@Suite struct NativePinchTests {
    @Test func spreadSendsMagnifyStreamInsteadOfShortcut() {
        let r = Rig { $0.nativeGestures = true }
        r.touch(Fixture.pair(mid, spread: 400))
        r.touch(Fixture.pair(mid, spread: 500))     // decides: pinch
        r.touch(Fixture.pair(mid, spread: 625))     // 25 % larger
        r.lift()
        let m = r.sink.magnifies
        #expect(m.count == 3)
        #expect(m[0].1 == .began && m[0].0 == 0)
        #expect(m[1].1 == .changed && near(m[1].0, 0.25))
        #expect(m[2].1 == .ended)
        #expect(r.sink.keys.isEmpty)
        #expect(r.sink.rotates.isEmpty)
    }

    @Test func pinchInGivesNegativeMagnification() {
        let r = Rig { $0.nativeGestures = true }
        r.touch(Fixture.pair(mid, spread: 800))
        r.touch(Fixture.pair(mid, spread: 700))
        r.touch(Fixture.pair(mid, spread: 560))
        #expect(r.sink.magnifies.last.map { near($0.0, -0.2) && $0.1 == .changed } == true)
    }

    @Test func twistSendsRotateStreamCounterClockwisePositive() {
        let r = Rig { $0.nativeGestures = true }
        r.touch(Fixture.pair(mid, spread: 600))
        r.touch(Fixture.pair(mid, spread: 600, degrees: 10))    // decides: twist
        r.touch(Fixture.pair(mid, spread: 600, degrees: 20))    // clockwise on screen
        r.touch(Fixture.pair(mid, spread: 600, degrees: 25))
        r.lift()
        let rot = r.sink.rotates
        #expect(rot.count == 4)
        #expect(rot[0].1 == .began && rot[0].0 == 0)
        #expect(rot[1].1 == .changed && near(rot[1].0, -20))    // includes the twist before the stream opened
        #expect(rot[2].1 == .changed && near(rot[2].0, -5))
        #expect(rot[3].1 == .ended)
        #expect(r.sink.magnifies.allSatisfy { abs($0.0) < 1e-6 })    // a pure twist does not zoom
        #expect(r.sink.magnifies.first?.1 == .began && r.sink.magnifies.last?.1 == .ended)
        #expect(r.sink.keys.isEmpty)
    }

    @Test func smallWobbleDuringPinchDoesNotRotate() {
        let r = Rig { $0.nativeGestures = true }
        r.touch(Fixture.pair(mid, spread: 400))
        r.touch(Fixture.pair(mid, spread: 500))
        r.touch(Fixture.pair(mid, spread: 600, degrees: 3))
        r.lift()
        #expect(r.sink.rotates.isEmpty)
    }

    @Test func thirdFingerClosesTheStreams() {
        let r = Rig { $0.nativeGestures = true }
        r.touch(Fixture.pair(mid, spread: 400))
        r.touch(Fixture.pair(mid, spread: 500))
        r.touch(Fixture.pair(mid, spread: 500) + [CGPoint(x: 1500, y: 1200)])
        #expect(r.sink.magnifies.map(\.1) == [.began, .ended])
    }

    @Test func offByDefaultKeepsShortcutsAndIgnoresTwist() {
        let r = Rig()
        r.touch(Fixture.pair(mid, spread: 400))
        r.touch(Fixture.pair(mid, spread: 500))
        r.touch(Fixture.pair(mid, spread: 700))
        r.lift()
        #expect(r.sink.magnifies.isEmpty)
        #expect(!r.sink.keys.isEmpty)

        let t = Rig()
        t.touch(Fixture.pair(mid, spread: 600))
        t.touch(Fixture.pair(mid, spread: 600, degrees: 20))
        t.lift()
        #expect(t.sink.rotates.isEmpty && t.sink.magnifies.isEmpty && t.sink.keys.isEmpty)
    }

    @Test func gesturesDisabledSuppressesNativePinch() {
        let r = Rig { $0.nativeGestures = true; $0.gesturesEnabled = false }
        r.touch(Fixture.pair(mid, spread: 400))
        r.touch(Fixture.pair(mid, spread: 700))
        r.lift()
        #expect(r.sink.magnifies.isEmpty && r.sink.rotates.isEmpty)
    }

    @Test func wrapDegreesTreatsSwappedFingersAsNoTurn() {
        #expect(near(GestureEngine.wrapDegrees(180), 0))
        #expect(near(GestureEngine.wrapDegrees(-175), 5))
        #expect(near(GestureEngine.wrapDegrees(100), -80))
        #expect(near(GestureEngine.wrapDegrees(30), 30))
    }
}

@Suite struct NativeSwipeTests {
    private func three(_ dx: CGFloat = 0, _ dy: CGFloat = 0) -> [CGPoint] {
        [1300, 1500, 1700].map { CGPoint(x: $0 + dx, y: 800 + dy) }
    }

    @Test func horizontalSwipeFollowsTheFingers() {
        let r = Rig { $0.nativeSwipes = true }
        r.touch(three())
        r.touch(three(-100))            // locks the axis
        r.clock.advance(0.05)
        r.touch(three(-400))            // 300 px past the lock point = 0.1 of the width
        r.lift()
        let s = r.sink.swipes
        #expect(s.count == 3)
        #expect(s.allSatisfy { $0.axis == .horizontal })
        #expect(s[0].phase == .began && s[0].progress == 0)
        #expect(s[1].phase == .changed && near(s[1].progress, 0.1))
        #expect(s[2].phase == .ended && near(s[2].progress, 0.1))
        #expect(s[2].velocity > 0)      // lifted while moving: a flick
        #expect(r.sink.keys.isEmpty)
    }

    @Test func swipeRightIsNegativeAndRestingFingerIsNotAFlick() {
        let r = Rig { $0.nativeSwipes = true }
        r.touch(three())
        r.touch(three(100))
        r.clock.advance(0.05)
        r.touch(three(400))
        r.clock.advance(0.5)
        r.lift()
        let s = r.sink.swipes
        #expect(s.last.map { near($0.progress, -0.1) && $0.velocity == 0 && $0.phase == .ended } == true)
    }

    @Test func upwardSwipeIsVerticalAndPositive() {
        let r = Rig { $0.nativeSwipes = true }
        r.touch(three())
        r.touch(three(10, -100))
        r.touch(three(10, -250))
        let s = r.sink.swipes
        #expect(s.first?.axis == .vertical)
        #expect((s.last?.progress ?? 0) > 0)
    }

    @Test func changingFingerCountEndsTheSwipe() {
        let r = Rig { $0.nativeSwipes = true }
        r.touch(three())
        r.touch(three(-100))
        r.touch(three(-100) + [CGPoint(x: 1800, y: 800)])
        #expect(r.sink.swipes.map(\.phase) == [.began, .ended])
    }

    @Test func offByDefaultFiresTheShortcut() {
        let r = Rig()
        r.touch(three())
        r.touch(three(-400))
        r.lift()
        #expect(r.sink.swipes.isEmpty)
        #expect(r.sink.keys == [GestureID.swipe3Left.defaultShortcut.keyCode!])
    }
}

@Suite struct CalibrationTests {
    private func pairs(_ f: (CGPoint) -> CGPoint) -> [(touch: CGPoint, target: CGPoint)] {
        CalibrationSession.defaultTargets.map { (f($0), $0) }
    }

    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

    @Test func perfectTouchesFitIdentity() throws {
        let cal = try #require(Calibration.fit(pairs { $0 }))
        #expect(close(cal.apply(CGPoint(x: 0.3, y: 0.7)), CGPoint(x: 0.3, y: 0.7)))
        #expect(cal.rmsError(pairs { $0 }) < 1e-9)
    }

    @Test func fitRecoversOffsetScaleAndRotation() throws {
        // Panel reports a shrunken, shifted image.
        let shrunk = pairs { CGPoint(x: 0.05 + 0.9 * $0.x, y: 0.02 + 0.95 * $0.y) }
        let a = try #require(Calibration.fit(shrunk))
        #expect(close(a.apply(CGPoint(x: 0.05 + 0.9 * 0.25, y: 0.02 + 0.95 * 0.6)), CGPoint(x: 0.25, y: 0.6)))
        // Panel mounted upside down.
        let flipped = try #require(Calibration.fit(pairs { CGPoint(x: 1 - $0.x, y: 1 - $0.y) }))
        #expect(close(flipped.apply(CGPoint(x: 0.2, y: 0.3)), CGPoint(x: 0.8, y: 0.7)))
        // Panel turned a quarter: axes swap.
        let quarter = try #require(Calibration.fit(pairs { CGPoint(x: $0.y, y: 1 - $0.x) }))
        #expect(close(quarter.apply(CGPoint(x: 0.3, y: 0.9)), CGPoint(x: 0.1, y: 0.3)))
    }

    @Test func degenerateInputGivesNoFit() {
        #expect(Calibration.fit([]) == nil)
        #expect(Calibration.fit(Array(pairs { $0 }.prefix(2))) == nil)
        let line = [0.1, 0.5, 0.9].map { (touch: CGPoint(x: $0, y: $0), target: CGPoint(x: $0, y: $0)) }
        #expect(Calibration.fit(line) == nil)
        // Every touch on one spot: nothing to scale from.
        #expect(Calibration.fit(pairs { _ in CGPoint(x: 0.5, y: 0.5) }) == nil)
    }

    @Test func validityRejectsNonFiniteAndCollapsedTransforms() {
        #expect(Calibration.identity.isValid)
        #expect(!Calibration(a: .nan, b: 0, c: 0, d: 0, e: 1, f: 0).isValid)
        #expect(!Calibration(a: 0.1, b: 0, c: 0, d: 0, e: 0.1, f: 0).isValid)
        #expect(!Calibration(a: 1, b: 0, c: 5, d: 0, e: 1, f: 0).isValid)
    }

    @Test func sessionCapturesOneTouchPerTargetOnLift() throws {
        var s = CalibrationSession()
        for t in CalibrationSession.defaultTargets {
            #expect(s.current == t)
            do { let f1 = s.feed([CGPoint(x: t.x + 0.004, y: t.y)]); #expect(!f1) }
            do { let f2 = s.feed([CGPoint(x: t.x - 0.004, y: t.y)]); #expect(!f2) }     // averaged with the first sample
            do { let f3 = s.feed([]); #expect(f3) }
        }
        #expect(s.isComplete && s.current == nil)
        let cal = try #require(s.result())
        #expect(close(cal.apply(CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 0.5, y: 0.5)))
        do { let f4 = s.feed([]); #expect(!f4) }
    }

    @Test func sessionIgnoresMultiFingerTouchesAndEmptyLifts() {
        var s = CalibrationSession()
        do { let f5 = s.feed([]); #expect(!f5) }
        do { let f6 = s.feed([CGPoint(x: 0.1, y: 0.1)]); #expect(!f6) }
        do { let f7 = s.feed([CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.4)]); #expect(!f7) }
        do { let f8 = s.feed([]); #expect(!f8) }
        #expect(s.index == 0)
        do { let f9 = s.feed([CGPoint(x: 0.1, y: 0.1)]); #expect(!f9) }
        do { let f10 = s.feed([]); #expect(f10) }
        #expect(s.index == 1)
    }

    @Test func missedTargetRejectsTheResult() {
        var s = CalibrationSession()
        for (i, t) in CalibrationSession.defaultTargets.enumerated() {
            _ = s.feed([i == 4 ? CGPoint(x: 0.9, y: 0.2) : t])
            _ = s.feed([])
        }
        #expect(s.isComplete)
        #expect(s.result() == nil)
    }

    @Test func mappingUsesCalibrationInsteadOfRotationAndClamps() {
        let b = CGRect(x: 100, y: 50, width: 1000, height: 500)
        let flip = Calibration(a: -1, b: 0, c: 1, d: 0, e: -1, f: 1)
        let p = Displays.map(CGPoint(x: 0.2, y: 0.2), rotation: 90, calibration: flip, bounds: b)
        #expect(close(p, CGPoint(x: 900, y: 450)))
        let shifted = Calibration(a: 1, b: 0, c: 0.5, d: 0, e: 1, f: -0.5)
        #expect(Displays.map(CGPoint(x: 0.9, y: 0.2), rotation: 0, calibration: shifted, bounds: b) == CGPoint(x: 1100, y: 50))
        #expect(Displays.map(CGPoint(x: 0.5, y: 0.5), rotation: 180, calibration: nil, bounds: b)
            == Displays.map(CGPoint(x: 0.5, y: 0.5), rotation: 180, bounds: b))
    }

    @Test func configDefaultsDecodeAndSanitize() throws {
        let d = try Fixture.decode("{}")
        #expect(!d.nativeGestures && !d.nativeSwipes && d.calibration == nil)

        var c = TouchConfig()
        c.nativeGestures = true; c.nativeSwipes = true
        c.calibration = Calibration(a: 0.9, b: 0.01, c: 0.05, d: -0.01, e: 0.95, f: 0.02)
        #expect(try Fixture.roundTrip(c) == c)
        #expect(c.sanitized().calibration == c.calibration)

        // A hand-edited transform that collapses the panel is dropped, as is a malformed one.
        let bad = try Fixture.decode(#"{"calibration": {"a": 0, "b": 0, "c": 0, "d": 0, "e": 0, "f": 0}}"#)
        #expect(bad.sanitized().calibration == nil)
        let junk = try Fixture.decode(#"{"calibration": "nope", "scrollSpeed": 3}"#)
        #expect(junk.calibration == nil && junk.scrollSpeed == 3)
    }
}
