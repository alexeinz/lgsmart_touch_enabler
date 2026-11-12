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
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var touches: [CGPoint] = []
    @Published private(set) var logs: [LogStore.Entry] = LogStore.shared.snapshot

    let store = ConfigStore()
    private let service: TouchService
    private var timer: Timer?

    init() {
        let cfg = store.load()
        config = cfg
        service = TouchService(config: cfg)
        service.onStatus = { [weak self] s in
            DispatchQueue.main.async { self?.status = s }
        }

        service.onTouches = { [weak self] pts in self?.touches = pts }
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

    func resetShortcuts() { config.resetBindings() }
    func resetSensitivity() { config.resetSensitivity() }

    private func persist() {
        if !store.save(config) { LogStore.shared.log("Could not save config", .error) }
        service.update(config: config)
        status = service.status
    }
}
