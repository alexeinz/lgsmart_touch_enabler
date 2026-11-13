import AppKit
import CoreGraphics
import Foundation

public struct DisplayInfo: Identifiable, Equatable {
    public let id: UInt32
    public let name: String
    public let isBuiltin: Bool
    public let bounds: CGRect
}

public enum Displays {
    public static func activeIDs() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &ids, &n)
        return ids
    }

    public static func all() -> [DisplayInfo] {
        let names: [UInt32: String] = Dictionary(
            NSScreen.screens.compactMap { s -> (UInt32, String)? in
                guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return (num.uint32Value, s.localizedName)
            }, uniquingKeysWith: { a, _ in a })
        return activeIDs().map { id in
            DisplayInfo(id: id, name: names[id] ?? "Display \(id)",
                        isBuiltin: CGDisplayIsBuiltin(id) != 0, bounds: CGDisplayBounds(id))
        }
    }

    /// The preferred display if still connected, otherwise the first external one, otherwise main.
    public static func target(preferred: UInt32?) -> CGDirectDisplayID {
        let ids = activeIDs()
        if let p = preferred, ids.contains(p) { return p }
        return ids.first(where: { CGDisplayIsBuiltin($0) == 0 }) ?? CGMainDisplayID()
    }

    /// Maps a raw contact to a global screen point. A calibration replaces the rotation setting;
    /// its result is clamped to the display.
    public static func map(_ n: CGPoint, rotation: Int, calibration: Calibration?, bounds b: CGRect) -> CGPoint {
        guard let cal = calibration else { return map(n, rotation: rotation, bounds: b) }
        let p = cal.apply(n)
        return CGPoint(x: b.minX + min(max(p.x, 0), 1) * b.width, y: b.minY + min(max(p.y, 0), 1) * b.height)
    }

    /// Maps a normalized (0...1, top-left origin) touch coordinate to global screen points,
    /// applying the panel rotation (degrees clockwise the panel is physically turned).
    public static func map(_ n: CGPoint, rotation: Int, bounds b: CGRect) -> CGPoint {
        var nx = n.x, ny = n.y
        switch rotation {
        case 90: (nx, ny) = (1 - n.y, n.x)
        case 180: (nx, ny) = (1 - n.x, 1 - n.y)
        case 270: (nx, ny) = (n.y, 1 - n.x)
        default: break
        }
        return CGPoint(x: b.origin.x + nx * b.width, y: b.origin.y + ny * b.height)
    }
}
