import AppKit
import SwiftUI
import TouchCore

@main
struct TouchdApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("LG Smart Touch Enabler", systemImage: model.status.isHealthy ? "hand.tap.fill" : "hand.tap") {
            MenuContent().environmentObject(model)
        }

        Window("LG Smart Touch Enabler", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        Divider()
        Toggle("Touch enabled", isOn: $model.config.enabled)
        Toggle("Gestures", isOn: $model.config.gesturesEnabled)
        Divider()
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Button("Quit LG Smart Touch Enabler") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        let s = model.status
        if !model.config.enabled { return "Disabled" }
        if !s.accessibility { return "⚠︎ Accessibility permission needed" }
        if !s.running { return "⚠︎ Input Monitoring permission needed" }
        if !s.deviceConnected { return "Touchscreen not connected" }
        return "Active on \(s.displayName)"
    }
}
