import CoreGraphics
import Foundation

/// A recording of raw contacts (normalized 0...1, digitizer orientation) with timestamps.
/// Traces captured on the real monitor can be replayed through the gesture engine in tests.
public struct TouchTrace: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        public var t: Double              // seconds since the first frame
        public var pts: [[Double]]        // [[x, y], …]
        public init(t: Double, pts: [[Double]]) { self.t = t; self.pts = pts }
        public var points: [CGPoint] { pts.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
    }

    public var version = 1
    public var rotation = 0
    public var displayWidth = 1920.0
    public var displayHeight = 1080.0
    public var frames: [Frame] = []

    public init(rotation: Int = 0, displayWidth: Double = 1920, displayHeight: Double = 1080, frames: [Frame] = []) {
        self.rotation = rotation; self.displayWidth = displayWidth; self.displayHeight = displayHeight
        self.frames = frames
    }

    public var duration: Double { frames.last?.t ?? 0 }

    public var bounds: CGRect { CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight) }

    /// Feeds the trace to a consumer. `advance(dt)` is called before each frame with the time that
    /// passed since the previous one (drive a manual clock with it); `update` gets screen points.
    public func replay(advance: (TimeInterval) -> Void, update: ([CGPoint], _ displayWidth: CGFloat) -> Void) {
        var last = 0.0
        for f in frames {
            advance(max(0, f.t - last)); last = f.t
            let pts = f.points.map { Displays.map($0, rotation: rotation, bounds: bounds) }
            update(pts, CGFloat(displayWidth))
        }
    }

    // MARK: Files

    public func write(to url: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> TouchTrace {
        try JSONDecoder().decode(TouchTrace.self, from: Data(contentsOf: url))
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("touchd/traces", isDirectory: true)
    }

    public static func newFileURL() -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return defaultDirectory.appendingPathComponent("trace-\(f.string(from: Date())).json")
    }
}

/// Collects frames while recording. Identical consecutive frames are dropped.
public final class TraceRecorder {
    public private(set) var trace: TouchTrace
    private var start: Date?
    public var frameCount: Int { trace.frames.count }

    public init(rotation: Int, bounds: CGRect) {
        trace = TouchTrace(rotation: rotation, displayWidth: Double(bounds.width), displayHeight: Double(bounds.height))
    }

    public func add(_ points: [CGPoint], at now: Date = Date()) {
        if start == nil { guard !points.isEmpty else { return }; start = now }   // begin at first touch
        let pts = points.map { [Double($0.x), Double($0.y)] }
        if trace.frames.last?.pts == pts { return }
        trace.frames.append(.init(t: now.timeIntervalSince(start!), pts: pts))
    }
}
