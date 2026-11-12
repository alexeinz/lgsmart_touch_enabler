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

        if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
        if !Permissions.inputMonitoringGranted { Permissions.requestInputMonitoring() }
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
            loginItemError = "Couldn't change login item: \(error.localizedDescription). Run the bundled Touchd.app from /Applications."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func resetShortcuts() { config.resetBindings() }
    func resetSensitivity() { config.resetSensitivity() }

    private func persist() {
        store.save(config)
        service.update(config: config)
        status = service.status
    }
}
