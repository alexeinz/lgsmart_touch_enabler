import AppKit
import SwiftUI
import TouchCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            SensitivityTab().tabItem { Label("Sensitivity", systemImage: "slider.horizontal.3") }
            GesturesTab().tabItem { Label("Gestures", systemImage: "hand.draw") }
            MonitorTab().tabItem { Label("Monitor", systemImage: "display") }
            PermissionsTab().tabItem { Label("Permissions", systemImage: "lock.shield") }
            LogsTab().tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 560, height: 500)
        .padding()
        .onAppear { model.refresh() }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Enable touchscreen", isOn: $model.config.enabled)
                Toggle("Enable multi-finger gestures", isOn: $model.config.gesturesEnabled)
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                        set: { model.setLaunchAtLogin($0) }))
                if let e = model.loginItemError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section("Display") {
                Picker("Touch display", selection: $model.config.displayID) {
                    Text("Automatic (first external)").tag(UInt32?.none)
                    ForEach(model.displays) { d in
                        Text("\(d.name) — \(Int(d.bounds.width))×\(Int(d.bounds.height))").tag(UInt32?.some(d.id))
                    }
                }
                Picker("Panel rotation", selection: $model.config.rotation) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                Text("Set this if touches land in the wrong place after rotating the monitor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Status") {
                StatusRow("Touchscreen", ok: model.status.deviceConnected,
                          okText: "Connected", badText: "Not found")
                StatusRow("Driver", ok: model.status.running && model.status.accessibility,
                          okText: "Running on \(model.status.displayName)", badText: "Needs permissions")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sensitivity

private struct SensitivityTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Scrolling") {
                slider("Scroll speed", $model.config.scrollSpeed, 0.25...4, "%.2f×")
                Toggle("Invert scroll direction", isOn: $model.config.invertScroll)
            }
            Section("Tapping") {
                slider("Drag threshold", $model.config.moveThreshold, 2...40, "%.0f pt")
                slider("Double-tap window", $model.config.doubleTapWindow, 0.15...1, "%.2f s")
                Toggle("Hold to right-click", isOn: $model.config.rightClickOnHold)
                slider("Hold duration", $model.config.longPressDelay, 0.3...2, "%.2f s")
                    .disabled(!model.config.rightClickOnHold)
            }
            Section("Gestures") {
                slider("Swipe distance", $model.config.swipeDistance, 0.02...0.25, "%.0f%% of width", scale: 100)
                slider("Zoom step", $model.config.zoomStep, 1.05...1.6, "%.2f×")
            }
            Section {
                Button("Reset sensitivity to defaults") { model.resetSensitivity() }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ format: String, scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 200)
                Text(String(format: format, value.wrappedValue * scale))
                    .monospacedDigit().frame(width: 100, alignment: .trailing)
            }
        }
    }
}

// MARK: - Gestures

private struct GesturesTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            ForEach([2, 3, 4, 5], id: \.self) { n in
                Section("\(n) fingers") {
                    ForEach(GestureID.allCases.filter { $0.fingers == n }, id: \.self) { g in
                        LabeledContent(g.title) {
                            ShortcutField(shortcut: Binding(
                                get: { model.config.shortcut(for: g) },
                                set: { model.config.setShortcut($0, for: g) }))
                        }
                    }
                }
            }
            Section {
                Button("Reset all shortcuts to defaults") { model.resetShortcuts() }
                Text("Space and Mission Control defaults need “Mission Control” keyboard shortcuts enabled in System Settings → Keyboard → Keyboard Shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                permission("Accessibility", granted: model.status.accessibility,
                           why: "Lets LG Smart Touch Enabler post clicks, scrolls and shortcuts.",
                           request: { Permissions.requestAccessibility() },
                           url: Permissions.accessibilitySettingsURL)
                permission("Input Monitoring", granted: model.status.inputMonitoring,
                           why: "Lets LG Smart Touch Enabler read the touchscreen's raw touch data.",
                           request: {
                               // macOS only prompts once; after that the user must flip the switch in Settings.
                               NSApp.activate(ignoringOtherApps: true)
                               if !Permissions.requestInputMonitoring() {
                                   NSWorkspace.shared.open(Permissions.inputMonitoringSettingsURL)
                               }
                           },
                           url: Permissions.inputMonitoringSettingsURL)
                if model.status.inputMonitoring && !model.status.running && model.config.enabled {
                    HStack {
                        Text("Input Monitoring is granted but touch input hasn't started. Relaunch to apply.")
                            .font(.caption)
                        Spacer()
                        Button("Relaunch") { model.relaunch() }
                    }
                }
                if !model.status.inputMonitoring {
                    Text("Add LG Smart Touch Enabler under Privacy & Security → Input Monitoring and switch it on, then relaunch. If it is listed but still missing after a rebuild, remove it with “−” and add it again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("About") {
                LabeledContent("Config file") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.store.url])
                    }
                }
                LabeledContent("Device") {
                    Text(String(format: "VID 0x%04X  PID 0x%04X", model.config.vendorID, model.config.productID))
                        .monospaced()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func permission(_ name: String, granted: Bool, why: String,
                            request: @escaping () -> Void, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                StatusRow(name, ok: granted, okText: "Granted", badText: "Missing")
                if !granted {
                    Button("Request", action: request)
                    Button("Open Settings") { NSWorkspace.shared.open(url) }
                }
            }
            Text(why).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StatusRow: View {
    let title: String, ok: Bool, okText: String, badText: String
    init(_ title: String, ok: Bool, okText: String, badText: String) {
        self.title = title; self.ok = ok; self.okText = okText; self.badText = badText
    }
    var body: some View {
        LabeledContent(title) {
            Label(ok ? okText : badText, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
        }
    }
}


// MARK: - Logs

private struct LogsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var showGestures = true
    @State private var autoScroll = true

    private var visible: [LogStore.Entry] {
        showGestures ? model.logs : model.logs.filter { $0.level != .gesture }
    }

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                List(visible) { e in
                    Text(e.line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(e.level))
                        .textSelection(.enabled)
                        .id(e.id)
                }
                .onChange(of: model.logs.count) { _ in
                    if autoScroll, let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack {
                Toggle("Gestures", isOn: $showGestures)
                Toggle("Auto-scroll", isOn: $autoScroll)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logs.map(\.line).joined(separator: "\n"), forType: .string)
                }
                Button("Reveal file") {
                    if let u = LogStore.shared.fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                }
                Button("Clear") { model.clearLogs() }
            }
        }
        .padding(.top, 4)
    }

    private func color(_ l: LogStore.Level) -> Color {
        switch l {
        case .error: return .red
        case .warn: return .orange
        case .gesture: return .blue
        case .info: return .primary
        }
    }
}

// MARK: - Monitor

private struct MonitorTab: View {
    @EnvironmentObject var model: AppModel
    @State private var modes: [ResolutionMode] = []
    @State private var current: String = ""
    @State private var volume: Double = 0.5
    @State private var muted = false
    @State private var hasSoftwareVolume = false
    @State private var input: DDC.Input = DDC.Input.all[0]
    @State private var ddcVolume: Double = 50
    @State private var message = ""

    private var display: CGDirectDisplayID { Displays.target(preferred: model.config.displayID) }

    var body: some View {
        Form {
            Section("Resolution") {
                Picker("Mode", selection: $current) {
                    ForEach(modes) { Text($0.title).tag($0.id) }
                }
                .onChange(of: current) { new in
                    guard let m = modes.first(where: { $0.id == new }), m != Resolution.current(for: display) else { return }
                    let ok = Resolution.set(m, on: display)
                    LogStore.shared.log("Resolution \(m.title): \(ok ? "ok" : "failed")", ok ? .info : .error)
                    message = ok ? "" : "Could not change resolution."
                }
            }
            Section("Sound") {
                if hasSoftwareVolume {
                    Slider(value: $volume, in: 0...1) { Text("Volume (\(Sound.deviceName ?? "output"))") }
                        .onChange(of: volume) { v in Sound.setVolume(Float(v)) }
                    Toggle("Mute", isOn: $muted).onChange(of: muted) { m in Sound.setMuted(m) }
                } else {
                    Text("The current output (\(Sound.deviceName ?? "unknown")) has no software volume. Use the monitor volume below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if DDC.isSupported {
                    Slider(value: $ddcVolume, in: 0...100, step: 1) { Text("Monitor volume") }
                        .onChange(of: ddcVolume) { v in DDC.set(.volume, UInt16(v)) }
                }
            }
            Section("Input source (DDC/CI)") {
                if DDC.isSupported {
                    Picker("Input", selection: $input) {
                        ForEach(DDC.Input.all) { Text($0.name).tag($0) }
                    }
                    Button("Switch input") {
                        let ok = DDC.set(.input, input.code)
                        LogStore.shared.log("Switch input to \(input.name): \(ok ? "sent" : "failed")", ok ? .info : .error)
                        message = ok ? "Sent. The monitor may blank while it switches." : "DDC write failed."
                    }
                    Text("Switching away from this Mac's input will make the screen go dark. Press the monitor's own input button to come back.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No DDC-capable external display found (Apple silicon Mac and an external monitor are required).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func reload() {
        modes = Resolution.modes(for: display)
        current = Resolution.current(for: display)?.id ?? ""
        if let v = Sound.volume { hasSoftwareVolume = true; volume = Double(v); muted = Sound.muted ?? false } else { hasSoftwareVolume = false }
    }
}
