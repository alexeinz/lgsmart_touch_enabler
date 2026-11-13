import CoreGraphics
import Foundation
@testable import TouchCore

final class RecordingSink: EventSink {
    enum Event: Equatable {
        case mouse(MouseEventKind, CGPoint, Int)
        case scroll(Int, Int)
        case key(UInt16, UInt64)
        case magnify(Double, GesturePhase)
        case rotate(Double, GesturePhase)
        case dockSwipe(SwipeAxis, Double, Double, GesturePhase)
    }
    var events: [Event] = []
    func mouse(_ kind: MouseEventKind, at p: CGPoint, clicks: Int) { events.append(.mouse(kind, p, clicks)) }
    func scroll(dx: Int, dy: Int) { events.append(.scroll(dx, dy)) }
    func key(_ code: UInt16, flags: CGEventFlags) { events.append(.key(code, flags.rawValue)) }

    func magnify(_ delta: Double, phase: GesturePhase) { events.append(.magnify(delta, phase)) }
    func rotate(_ degrees: Double, phase: GesturePhase) { events.append(.rotate(degrees, phase)) }
    func dockSwipe(_ axis: SwipeAxis, progress: Double, velocity: Double, phase: GesturePhase) {
        events.append(.dockSwipe(axis, progress, velocity, phase))
    }

    var magnifies: [(Double, GesturePhase)] { events.compactMap { if case .magnify(let d, let p) = $0 { return (d, p) } else { return nil } } }
    var rotates: [(Double, GesturePhase)] { events.compactMap { if case .rotate(let d, let p) = $0 { return (d, p) } else { return nil } } }
    var swipes: [(axis: SwipeAxis, progress: Double, velocity: Double, phase: GesturePhase)] {
        events.compactMap { if case .dockSwipe(let a, let p, let v, let ph) = $0 { return (a, p, v, ph) } else { return nil } }
    }
    var keys: [UInt16] { events.compactMap { if case .key(let c, _) = $0 { return c } else { return nil } } }
    var scrolls: [(Int, Int)] { events.compactMap { if case .scroll(let x, let y) = $0 { return (x, y) } else { return nil } } }
    var kinds: [MouseEventKind] { events.compactMap { if case .mouse(let k, _, _) = $0 { return k } else { return nil } } }
}

/// Deterministic clock + timers.
final class ManualClock {
    var time = Date(timeIntervalSince1970: 1_000_000)
    private var timers: [(id: Int, due: Date, block: () -> Void)] = []
    private var nextID = 0

    func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        timers.append((id, time.addingTimeInterval(delay), block))
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    func advance(_ dt: TimeInterval) {
        time = time.addingTimeInterval(dt)
        let due = timers.filter { $0.due <= time }.sorted { $0.due < $1.due }
        timers.removeAll { t in due.contains { $0.id == t.id } }
        due.forEach { $0.block() }
    }
}

struct Rig {
    let sink = RecordingSink()
    let clock = ManualClock()
    var config = TouchConfig()
    let engine: GestureEngine

    init(_ configure: (inout TouchConfig) -> Void = { _ in }) {
        var cfg = TouchConfig(); configure(&cfg)
        let box = ConfigBox(cfg)
        let clock = self.clock
        engine = GestureEngine(sink: sink, config: { box.value },
                               schedule: { clock.schedule($0, $1) }, now: { clock.time })
        config = cfg
    }
    static let width: CGFloat = 3000
    func touch(_ pts: [CGPoint]) { engine.update(points: pts, displayWidth: Rig.width) }
    func lift() { engine.update(points: [], displayWidth: Rig.width) }

    /// Replays a recorded trace with the manual clock driving timers.
    func replay(_ trace: TouchTrace) {
        trace.replay(advance: { clock.advance($0) }, update: { engine.update(points: $0, displayWidth: $1) })
    }
}

final class ConfigBox { var value: TouchConfig; init(_ v: TouchConfig) { value = v } }

// Foundation-dependent helpers live here: files that import both Testing and Foundation fail to
// compile under Command Line Tools (the _Testing_Foundation overlay ships without a module).
enum Fixture {
    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("touchd-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json")
    }
    static func roundTrip(_ c: TouchConfig) throws -> TouchConfig {
        try JSONDecoder().decode(TouchConfig.self, from: try JSONEncoder().encode(c))
    }
    static func decode(_ json: String) throws -> TouchConfig {
        try JSONDecoder().decode(TouchConfig.self, from: Data(json.utf8))
    }
    static func writeCorrupt(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
    }
    /// Two fingers `spread` apart around `c`, turned `degrees` from horizontal.
    static func pair(_ c: CGPoint, spread: CGFloat, degrees: Double = 0) -> [CGPoint] {
        let a = degrees * .pi / 180, dx = CGFloat(cos(a)) * spread / 2, dy = CGFloat(sin(a)) * spread / 2
        return [CGPoint(x: c.x - dx, y: c.y - dy), CGPoint(x: c.x + dx, y: c.y + dy)]
    }
    static func date(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }
    static func traceRoundTrip(_ t: TouchTrace) throws -> TouchTrace {
        let url = tempURL()
        try t.write(to: url)
        return try TouchTrace.read(from: url)
    }
    /// A one-finger drag from (x0,y0) to (x1,y1), normalized, `n` frames at `dt` seconds.
    static func dragTrace(from a: CGPoint, to b: CGPoint, n: Int = 20, dt: Double = 0.016) -> TouchTrace {
        var t = TouchTrace(rotation: 0, displayWidth: Double(Rig.width), displayHeight: 1700)
        for i in 0...n {
            let f = Double(i) / Double(n)
            t.frames.append(.init(t: Double(i) * dt, pts: [[Double(a.x) + (Double(b.x) - Double(a.x)) * f, Double(a.y) + (Double(b.y) - Double(a.y)) * f]]))
        }
        t.frames.append(.init(t: Double(n + 1) * dt, pts: []))
        return t
    }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}
