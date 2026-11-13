import CoreGraphics
import Testing
@testable import TouchCore

@Suite struct TraceTests {
    @Test func traceSurvivesFileRoundTrip() throws {
        let t = Fixture.dragTrace(from: CGPoint(x: 0.2, y: 0.5), to: CGPoint(x: 0.6, y: 0.5))
        #expect(try Fixture.traceRoundTrip(t) == t)
    }

    @Test func replayedDragProducesMouseDrag() {
        let rig = Rig()
        rig.replay(Fixture.dragTrace(from: CGPoint(x: 0.2, y: 0.5), to: CGPoint(x: 0.6, y: 0.5)))
        #expect(rig.sink.kinds.contains(.leftDown))
        #expect(rig.sink.kinds.contains(.leftDrag))
        #expect(rig.sink.kinds.last == .leftUp)
    }

    @Test func recorderDropsDuplicateFramesAndStartsAtFirstTouch() {
        let r = TraceRecorder(rotation: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        r.add([], at: Fixture.date(0))
        r.add([CGPoint(x: 0.1, y: 0.1)], at: Fixture.date(1))
        r.add([CGPoint(x: 0.1, y: 0.1)], at: Fixture.date(1.1))
        r.add([CGPoint(x: 0.2, y: 0.1)], at: Fixture.date(1.5))
        #expect(r.frameCount == 2)
        #expect(r.trace.frames[0].t == 0)
        #expect(abs(r.trace.frames[1].t - 0.5) < 1e-9)
    }
}
