import Foundation
import ServiceManagement
import SwiftUI
import TouchCore

/// Single source of truth for the UI: owns the config, the running service and login-item state.
@MainActor
final class AppModel: ObservableObject {
    @Published var config: TouchConfig {
        didSet { if config != oldValue { persist() } }
    }
    @Published private(set) var status = ServiceStatus()
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemError: String?
    @Published private(set) var uninstallError: String?
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var touches: [CGPoint] = []
    @Published private(set) var logs: [LogStore.Entry] = LogStore.shared.snapshot
    @Published private(set) var calibrating = false
    @Published private(set) var calibrationMessage: String?

    let store = ConfigStore()
    private let service: TouchService
    private var timer: Timer?
    private let overlay = OverlayController()
    private let ax = AXWindowService()
    private let calibrationOverlay = CalibrationOverlay()
    private var calibrationSession: CalibrationSession?
    private var calibrationTimeout: DispatchWorkItem?

    init() {
        let cfg = store.load()
        config = cfg
        service = TouchService(config: cfg)
        service.onStatus = { [weak self] s in
            DispatchQueue.main.async { self?.status = s }
        }

        service.onTouches = { [weak self] pts in self?.touches = pts; self?.calibrationFeed(pts) }
        ax.onHandle = { [weak self] r in self?.overlay.setHandle(r) }
        ax.onPreview = { [weak self] r in self?.overlay.setPreview(r) }
        service.windows = ax
        service.onScreenPoints = { [weak self] pts in
            guard let self, self.config.touchRipple else { return }
            self.overlay.contacts(pts)
        }
        LogStore.shared.onAppend = { [weak self] entry in
            DispatchQueue.main.async {
                guard let self else { return }
                self.logs.append(entry)
                if self.logs.count > 1000 { self.logs.removeFirst(self.logs.count - 1000) }
            }
        }
        service.log = { LogStore.shared.log($0, .gesture) }
        LogStore.shared.log("LG Smart Touch Enabler started")

        if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
        Permissions.requestInputMonitoring()
        service.start()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-read permissions, devices and login-item state. Also retries starting the HID source
    /// once permission has been granted.
    func refresh() {
        if config.enabled && !status.running { service.start() }
        service.refreshStatus()
        status = service.status
        displays = Displays.all()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Trace recording (Test tab)

    @Published private(set) var recording = false
    @Published private(set) var lastTrace: URL?
    @Published private(set) var recordMessage: String?

    func toggleRecording() {
        if service.isRecording {
            recording = false
            guard let trace = service.stopRecording() else { recordMessage = "Nothing recorded: touch the screen while recording."; return }
            let url = TouchTrace.newFileURL()
            do {
                try trace.write(to: url)
                lastTrace = url
                recordMessage = String(format: "Saved %d frames (%.1f s)", trace.frames.count, trace.duration)
                LogStore.shared.log("Recorded trace \(url.lastPathComponent)")
            } catch { recordMessage = "Could not save: \(error.localizedDescription)" }
        } else {
            service.startRecording(); recording = true; recordMessage = "Recording… perform the gesture, then press Stop."
        }
    }

    func revealTrace() {
        if let u = lastTrace { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        else { NSWorkspace.shared.open(TouchTrace.defaultDirectory) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change login item: \(error.localizedDescription). Run the bundled app from /Applications."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func clearLogs() { LogStore.shared.clear(); logs = [] }

    /// Starts a fresh copy of the app and quits this one. Input Monitoring grants usually only
    /// take effect for a process that starts after the grant.
    func relaunch() {
        LogStore.shared.log("Relaunching")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Nil when not running from a bundle (e.g. `swift run`), where there is nothing to reset or uninstall.
    var bundleID: String? { Bundle.main.bundleIdentifier }
    var canUninstall: Bool { bundleID != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Clears this app's Accessibility and Input Monitoring entries, then relaunches so macOS asks again.
    func resetPermissions() {
        guard let id = bundleID else { return }
        LogStore.shared.log(Permissions.reset(bundleID: id) ? "Permissions reset" : "Permission reset failed", .warn)
        relaunch()
    }

    /// Removes the login item and the privacy grants, moves the app to the Trash and quits.
    /// macOS does none of this when an app is simply dragged to the Trash. The config file is kept.
    func uninstall() {
        guard canUninstall, let id = bundleID else { return }
        service.stop()
        try? SMAppService.mainApp.unregister()
        Permissions.reset(bundleID: id)
        do {
            try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        } catch {
            uninstallError = "Permissions and the login item were removed, but the app could not be moved to the Trash: \(error.localizedDescription)"
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Calibration

    /// Shows targets on the touch display and fits a correction from where the touches land.
    /// Input injection is suspended meanwhile, so the touches don't click anything.
    func startCalibration() {
        guard !calibrating else { return }
        let bounds = CGDisplayBounds(Displays.target(preferred: config.displayID))
        let session = CalibrationSession()
        guard let first = session.current else { return }
        calibrationSession = session
        calibrating = true
        calibrationMessage = nil
        service.suspended = true
        calibrationOverlay.show(bounds: bounds) { [weak self] in self?.endCalibration("Calibration cancelled.") }
        calibrationOverlay.setTarget(first, step: 1, of: session.targets.count)
        armCalibrationTimeout()
        LogStore.shared.log("Calibration started")
    }

    func clearCalibration() {
        config.calibration = nil
        calibrationMessage = "Calibration cleared."
    }

    private func calibrationFeed(_ pts: [CGPoint]) {
        guard var session = calibrationSession else { return }
        let captured = session.feed(pts)
        calibrationSession = session
        guard captured else { return }
        if let next = session.current {
            calibrationOverlay.setTarget(next, step: session.index + 1, of: session.targets.count)
            armCalibrationTimeout()
        } else if let cal = session.result() {
            config.calibration = cal
            endCalibration(String(format: "Calibrated (fit error %.1f%% of the screen).", cal.rmsError(session.pairs) * 100))
        } else {
            endCalibration("Calibration failed: the touches didn't line up with the targets. Try again.")
        }
    }

    private func armCalibrationTimeout() {
        calibrationTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.endCalibration("Calibration timed out.") }
        calibrationTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func endCalibration(_ message: String) {
        guard calibrating else { return }
        calibrationTimeout?.cancel(); calibrationTimeout = nil
        calibrationSession = nil
        calibrationOverlay.hide()
        service.suspended = false
        calibrating = false
        calibrationMessage = message
        LogStore.shared.log(message)
    }

    func resetShortcuts() { config.resetBindings() }
    func resetSensitivity() { config.resetSensitivity() }

    private func persist() {
        if !store.save(config) { LogStore.shared.log("Could not save config", .error) }
        service.update(config: config)
        status = service.status
    }
}
