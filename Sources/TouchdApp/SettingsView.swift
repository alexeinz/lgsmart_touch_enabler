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
            PermissionsTab().tabItem { Label("Permissions", systemImage: "lock.shield") }
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
                           why: "Lets Touchd post clicks, scrolls and shortcuts.",
                           request: Permissions.requestAccessibility,
                           url: Permissions.accessibilitySettingsURL)
                permission("Input Monitoring", granted: model.status.inputMonitoring,
                           why: "Lets Touchd read the touchscreen's raw touch data.",
                           request: Permissions.requestInputMonitoring,
                           url: Permissions.inputMonitoringSettingsURL)
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
