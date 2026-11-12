import CoreGraphics
import Foundation

public struct ServiceStatus: Equatable {
    public var running = false
    public var deviceConnected = false
    public var accessibility = false
    public var inputMonitoring = false
    public var displayName = ""

    public init() {}

    public var isHealthy: Bool { running && deviceConnected && accessibility }
}

/// Wires the HID source, gesture engine and event sink together. Main thread only.
public final class TouchService {
    public private(set) var config: TouchConfig
    public private(set) var status = ServiceStatus()
    public var onStatus: ((ServiceStatus) -> Void)?
    public var log: ((String) -> Void)? { didSet { engine.log = log } }
    private let logs = LogStore.shared
    private var lastStartFailed = false

    private let source = HIDTouchSource()
    private let engine: GestureEngine
    private var bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private var wasTouching = false

    public init(config: TouchConfig, sink: EventSink = CGEventSink()) {
        self.config = config
        var cfgRef: (() -> TouchConfig)?
        engine = GestureEngine(
            sink: sink,
            config: { cfgRef?() ?? TouchConfig() },
            schedule: { delay, block in
                let item = DispatchWorkItem(block: block)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                return { item.cancel() }
            })
        cfgRef = { [unowned self] in self.config }
        source.onChange = { [weak self] pts in self?.handle(pts) }
        source.onConnection = { [weak self] _ in self?.refreshStatus() }
    }

    // MARK: Lifecycle

    /// Starts reading the touchscreen. Returns false if the HID manager couldn't be opened
    /// (usually: Input Monitoring not granted).
    @discardableResult
    public func start() -> Bool {
        guard config.enabled else { refreshStatus(); return false }
        refreshDisplay()
        let ok = source.start(vendorID: config.vendorID, productID: config.productID)
        if ok {
            if lastStartFailed || !status.running { logs.log("Reading touchscreen (VID 0x\(String(config.vendorID, radix: 16, uppercase: true)) PID 0x\(String(config.productID, radix: 16, uppercase: true)))") }
            lastStartFailed = false
        } else if !lastStartFailed {
            lastStartFailed = true
            logs.log("Could not open the HID device; Input Monitoring is \(Permissions.inputMonitoringState.rawValue)", .warn)
        }
        refreshStatus()
        return ok
    }

    public func stop() {
        engine.reset()
        source.stop()
        refreshStatus()
    }

    /// Apply new settings live. Restarts the HID source only if the device or enabled flag changed.
    public func update(config new: TouchConfig) {
        let old = config
        config = new
        if !new.enabled { engine.reset() }
        if old.enabled != new.enabled || old.vendorID != new.vendorID || old.productID != new.productID {
            source.stop()
            if new.enabled { source.start(vendorID: new.vendorID, productID: new.productID) }
        }
        refreshDisplay()
        refreshStatus()
    }

    /// Re-read permissions / connection (cheap; call from a UI timer or on app activation).
    public func refreshStatus() {
        var s = ServiceStatus()
        s.running = source.isRunning
        s.deviceConnected = source.isConnected
        s.accessibility = Permissions.accessibilityGranted
        s.inputMonitoring = Permissions.inputMonitoringGranted
        s.displayName = Displays.all().first(where: { $0.id == Displays.target(preferred: config.displayID) })?.name ?? ""
        if s != status {
            logStatusChanges(from: status, to: s)
            status = s
            onStatus?(s)
        }
    }

    private func logStatusChanges(from o: ServiceStatus, to n: ServiceStatus) {
        if o.accessibility != n.accessibility { logs.log("Accessibility \(n.accessibility ? "granted" : "missing")", n.accessibility ? .info : .warn) }
        if o.inputMonitoring != n.inputMonitoring { logs.log("Input Monitoring \(n.inputMonitoring ? "granted" : "missing")", n.inputMonitoring ? .info : .warn) }
        if o.deviceConnected != n.deviceConnected { logs.log(n.deviceConnected ? "Touchscreen connected" : "Touchscreen disconnected", n.deviceConnected ? .info : .warn) }
        if o.running != n.running && !n.running { logs.log("Touch input stopped", .info) }
        if o.displayName != n.displayName && !n.displayName.isEmpty { logs.log("Target display: \(n.displayName)") }
    }

    public func refreshDisplay() {
        bounds = CGDisplayBounds(Displays.target(preferred: config.displayID))
    }

    // MARK: Touch handling

    private func handle(_ normalized: [CGPoint]) {
        guard config.enabled else { return }
        let touching = !normalized.isEmpty
        if touching && !wasTouching { refreshDisplay() }   // pick up display changes between touches
        wasTouching = touching
        let pts = normalized.map { Displays.map($0, rotation: config.rotation, bounds: bounds) }
        engine.update(points: pts, displayWidth: bounds.width)
    }
}
