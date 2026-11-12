import CoreAudio
import CoreGraphics
import Foundation
import IOKit

// MARK: - Resolution

public struct ResolutionMode: Identifiable, Equatable {
    public let width: Int
    public let height: Int
    public let hz: Int
    public let hiDPI: Bool
    public var id: String { "\(width)x\(height)@\(hz)\(hiDPI ? "h" : "")" }
    public var title: String { "\(width) × \(height) @ \(hz) Hz" + (hiDPI ? " (HiDPI)" : "") }
}

public enum Resolution {
    public static func modes(for display: CGDirectDisplayID) -> [ResolutionMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let list = CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode] else { return [] }
        var seen = Set<String>()
        return list.filter { $0.isUsableForDesktopGUI() }.compactMap { m in
            let r = ResolutionMode(width: m.width, height: m.height, hz: Int(m.refreshRate.rounded()),
                                   hiDPI: m.pixelWidth > m.width)
            return seen.insert(r.id).inserted ? r : nil
        }.sorted { ($0.width * $0.height, $0.hz) > ($1.width * $1.height, $1.hz) }
    }

    public static func current(for display: CGDirectDisplayID) -> ResolutionMode? {
        guard let m = CGDisplayCopyDisplayMode(display) else { return nil }
        return ResolutionMode(width: m.width, height: m.height, hz: Int(m.refreshRate.rounded()), hiDPI: m.pixelWidth > m.width)
    }

    @discardableResult
    public static func set(_ mode: ResolutionMode, on display: CGDirectDisplayID) -> Bool {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let list = CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode],
              let target = list.first(where: {
                  $0.width == mode.width && $0.height == mode.height && Int($0.refreshRate.rounded()) == mode.hz
                      && ($0.pixelWidth > $0.width) == mode.hiDPI && $0.isUsableForDesktopGUI()
              }) else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(cfg, display, target, nil)
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }
}

// MARK: - Sound (macOS output device)

public enum Sound {
    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    private static func addr(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// 0...1, or nil when the current output has no software volume (typical for HDMI/DisplayPort audio).
    public static var volume: Float? {
        guard let dev = defaultOutput() else { return nil }
        var a = addr(AudioObjectPropertySelector(0x766D7663))
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    public static func setVolume(_ value: Float) -> Bool {
        guard let dev = defaultOutput() else { return false }
        var a = addr(AudioObjectPropertySelector(0x766D7663))
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return false }
        var v = Float32(max(0, min(1, value)))
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    public static var muted: Bool? {
        guard let dev = defaultOutput() else { return nil }
        var a = addr(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &m) == noErr ? m != 0 : nil
    }

    @discardableResult
    public static func setMuted(_ on: Bool) -> Bool {
        guard let dev = defaultOutput() else { return false }
        var a = addr(kAudioDevicePropertyMute)
        var m: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }

    public static var deviceName: String? {
        guard let dev = defaultOutput() else { return nil }
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }
}

// MARK: - DDC/CI (monitor input, volume, brightness) on Apple silicon

/// Talks DDC/CI to an external display through the private IOAVService API (the same route m1ddc uses).
/// Not available on Intel Macs. Input codes differ per monitor; `Input.all` lists the common MCCS values.
public enum DDC {
    public struct Input: Identifiable, Hashable {
        public let name: String
        public let code: UInt16
        public var id: UInt16 { code }
        public static let all: [Input] = [
            .init(name: "HDMI 1", code: 0x11), .init(name: "HDMI 2", code: 0x12),
            .init(name: "DisplayPort 1", code: 0x0F), .init(name: "DisplayPort 2", code: 0x10),
            .init(name: "USB-C", code: 0x1B),
        ]
    }

    public enum VCP: UInt8 { case brightness = 0x10, input = 0x60, volume = 0x62, mute = 0x8D }

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias ReadFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func sym<T>(_ n: String, _: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, n) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    public static var isSupported: Bool { service() != nil }

    private static func service() -> CFTypeRef? {
        #if arch(arm64)
        guard let create = sym("IOAVServiceCreateWithService", CreateFn.self) else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while case let e = IOIteratorNext(iter), e != 0 {
            defer { IOObjectRelease(e) }
            let loc = IORegistryEntryCreateCFProperty(e, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let s = create(kCFAllocatorDefault, e) { return s.takeRetainedValue() }
        }
        #endif
        return nil
    }

    @discardableResult
    public static func set(_ vcp: VCP, _ value: UInt16) -> Bool {
        guard let svc = service(), let write = sym("IOAVServiceWriteI2C", WriteFn.self) else { return false }
        var buf: [UInt8] = [0x84, 0x03, vcp.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)]
        buf.append(buf.reduce(UInt8(0x6E ^ 0x51), ^))
        for _ in 0..<2 {  // DDC is flaky; send twice like m1ddc
            guard buf.withUnsafeMutableBytes({ write(svc, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }) == 0 else { return false }
            usleep(50_000)
        }
        return true
    }

    public static func get(_ vcp: VCP) -> UInt16? {
        guard let svc = service(), let write = sym("IOAVServiceWriteI2C", WriteFn.self),
              let read = sym("IOAVServiceReadI2C", ReadFn.self) else { return nil }
        var req: [UInt8] = [0x82, 0x01, vcp.rawValue]
        req.append(req.reduce(UInt8(0x6E ^ 0x51), ^))
        guard req.withUnsafeMutableBytes({ write(svc, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }) == 0 else { return nil }
        usleep(50_000)
        var reply = [UInt8](repeating: 0, count: 12)
        guard reply.withUnsafeMutableBytes({ read(svc, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }) == 0 else { return nil }
        // reply: [len, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, chk]
        return UInt16(reply[8]) << 8 | UInt16(reply[9])
    }

    /// Raw VCP read: current and maximum value, or nil if unsupported / no reply.
    public static func getRaw(_ code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let svc = service(), let write = sym("IOAVServiceWriteI2C", WriteFn.self),
              let read = sym("IOAVServiceReadI2C", ReadFn.self) else { return nil }
        var req: [UInt8] = [0x82, 0x01, code]
        req.append(req.reduce(UInt8(0x6E ^ 0x51), ^))
        let dbg = ProcessInfo.processInfo.environment["TOUCHD_DDC_DEBUG"] != nil
        let wr = req.withUnsafeMutableBytes({ write(svc, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) })
        if dbg { FileHandle.standardError.write(Data("write rc=\(wr)\n".utf8)) }
        guard wr == 0 else { return nil }
        usleep(50_000)
        var r = [UInt8](repeating: 0, count: 12)
        let rr = r.withUnsafeMutableBytes({ read(svc, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) })
        if dbg { FileHandle.standardError.write(Data("read rc=\(rr)\n".utf8)) }
        guard rr == 0 else { return nil }
        if ProcessInfo.processInfo.environment["TOUCHD_DDC_DEBUG"] != nil {
            FileHandle.standardError.write(Data("VCP 0x\(String(code, radix: 16)) reply: \(r.map { String(format: "%02X", $0) }.joined(separator: " "))\n".utf8))
        }
        guard r[3] == 0 else { return nil }   // 0 = ok, 1 = unsupported VCP code
        return (UInt16(r[8]) << 8 | UInt16(r[9]), UInt16(r[6]) << 8 | UInt16(r[7]))
    }

    /// The monitor's MCCS capabilities string, e.g. "(prot(monitor)... vcp(10 60(0F 11 12) 62) ...)".
    public static func capabilities() -> String? {
        guard let svc = service(), let write = sym("IOAVServiceWriteI2C", WriteFn.self),
              let read = sym("IOAVServiceReadI2C", ReadFn.self) else { return nil }
        var out = [UInt8]()
        var offset = 0
        while offset < 2048 {
            var req: [UInt8] = [0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)]
            req.append(req.reduce(UInt8(0x6E ^ 0x51), ^))
            guard req.withUnsafeMutableBytes({ write(svc, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }) == 0 else { break }
            usleep(60_000)
            var r = [UInt8](repeating: 0, count: 40)
            guard r.withUnsafeMutableBytes({ read(svc, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }) == 0 else { break }
            guard r[2] == 0xE3 else { break }
            let n = Int(r[1] & 0x7F) - 3
            if n <= 0 { break }
            out += r[5..<min(5 + n, r.count)]
            offset += n
        }
        return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
    }
}
