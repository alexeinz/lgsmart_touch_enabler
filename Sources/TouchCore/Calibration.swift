import CoreGraphics
import Foundation

/// Affine correction from raw digitizer coordinates (normalized 0...1) to the position on the
/// display (normalized 0...1, top-left origin):
///
///     x' = a·x + b·y + c
///     y' = d·x + e·y + f
///
/// It is fitted from touches on known targets, so it absorbs offset, scale, skew, mirroring and
/// panel rotation in one step.
public struct Calibration: Codable, Equatable, Sendable {
    public var a = 1.0, b = 0.0, c = 0.0
    public var d = 0.0, e = 1.0, f = 0.0

    public static let identity = Calibration()

    public init() {}

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    /// Maps a raw point to display space without clamping.
    public func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        return CGPoint(x: a * x + b * y + c, y: d * x + e * y + f)
    }

    /// False for transforms that are not finite or that squash/blow up the panel beyond anything a
    /// real calibration produces (hand-edited or corrupt config).
    public var isValid: Bool {
        guard [a, b, c, d, e, f].allSatisfy({ $0.isFinite }) else { return false }
        let det = abs(a * e - b * d)
        return det > 0.25 && det < 4 && abs(c) < 2 && abs(f) < 2
    }

    /// Least-squares fit over `pairs`. Needs at least three touches that are not on one line.
    public static func fit(_ pairs: [(touch: CGPoint, target: CGPoint)]) -> Calibration? {
        guard pairs.count >= 3 else { return nil }
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0
        var bx = [0.0, 0.0, 0.0], by = [0.0, 0.0, 0.0]
        for p in pairs {
            let x = Double(p.touch.x), y = Double(p.touch.y)
            let tx = Double(p.target.x), ty = Double(p.target.y)
            sxx += x * x; sxy += x * y; syy += y * y; sx += x; sy += y
            bx[0] += x * tx; bx[1] += y * tx; bx[2] += tx
            by[0] += x * ty; by[1] += y * ty; by[2] += ty
        }
        let m = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, Double(pairs.count)]]
        guard let r1 = solve3(m, bx), let r2 = solve3(m, by) else { return nil }
        let cal = Calibration(a: r1[0], b: r1[1], c: r1[2], d: r2[0], e: r2[1], f: r2[2])
        return cal.isValid ? cal : nil
    }

    /// Root-mean-square distance between mapped touches and their targets, in normalized units.
    public func rmsError(_ pairs: [(touch: CGPoint, target: CGPoint)]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        let sum = pairs.reduce(0.0) { acc, p in
            let q = apply(p.touch)
            let dx = Double(q.x - p.target.x), dy = Double(q.y - p.target.y)
            return acc + dx * dx + dy * dy
        }
        return (sum / Double(pairs.count)).squareRoot()
    }

    /// Cramer's rule; nil when the system is (near) singular.
    private static func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d0 = det(m)
        guard abs(d0) > 1e-9 else { return nil }
        return (0..<3).map { col in
            var mm = m
            for row in 0..<3 { mm[row][col] = v[row] }
            return det(mm) / d0
        }
    }
}

/// Collects one touch per on-screen target and produces a `Calibration`. Pure state machine:
/// feed it the raw contact list on every change.
public struct CalibrationSession {
    /// Four inset corners and the centre, in normalized display space.
    public static let defaultTargets: [CGPoint] = [
        CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.9, y: 0.9),
        CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.5, y: 0.5),
    ]

    public let targets: [CGPoint]
    public private(set) var pairs: [(touch: CGPoint, target: CGPoint)] = []
    private var sum = CGPoint.zero
    private var count = 0
    private var multi = false

    public init(targets: [CGPoint] = CalibrationSession.defaultTargets) { self.targets = targets }

    public var index: Int { pairs.count }
    public var isComplete: Bool { pairs.count >= targets.count }
    /// The target to show now, nil once all are captured.
    public var current: CGPoint? { isComplete ? nil : targets[pairs.count] }

    /// Returns true when a lift just captured the current target. A touch that involved more than
    /// one finger is ignored. The captured position is the average over the whole touch.
    public mutating func feed(_ pts: [CGPoint]) -> Bool {
        guard !isComplete else { return false }
        if let p = pts.first {
            if pts.count > 1 { multi = true }
            sum.x += p.x; sum.y += p.y; count += 1
            return false
        }
        defer { sum = .zero; count = 0; multi = false }
        guard count > 0, !multi else { return false }
        let touch = CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count))
        pairs.append((touch, targets[pairs.count]))
        return true
    }

    /// The fitted transform, or nil when incomplete, degenerate, or when the touches disagree with
    /// the fit by more than `maxError` (e.g. a target was missed).
    public func result(maxError: Double = 0.03) -> Calibration? {
        guard isComplete, let cal = Calibration.fit(pairs), cal.rmsError(pairs) <= maxError else { return nil }
        return cal
    }
}
