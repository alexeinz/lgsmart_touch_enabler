import AppKit
import SwiftUI
import TouchCore

@main
struct TouchdApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }

        Window("LG Smart Touch Enabler", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

/// Always instantiated, so it can open the settings window at launch when a permission is missing.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(active: model.status.isHealthy, warning: !model.status.accessibility || !model.status.inputMonitoring))
            .task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                model.refresh()
                if !model.status.accessibility || !model.status.inputMonitoring {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

/// Template menu-bar glyph: a monitor with a touch point. Warning state adds a badge dot.
enum MenuBarIcon {
    static func image(active: Bool, warning: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4.5, width: 17, height: 10), xRadius: 2, yRadius: 2)
            screen.lineWidth = 1.4; screen.stroke()
            let stand = NSBezierPath(); stand.lineWidth = 1.4
            stand.move(to: NSPoint(x: 6, y: 1.5)); stand.line(to: NSPoint(x: 14, y: 1.5)); stand.stroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: 7.5, y: 6.5, width: 5, height: 5))
            if active { dot.fill() } else { dot.lineWidth = 1.2; dot.stroke() }
            if warning { NSBezierPath(ovalIn: NSRect(x: 14, y: 10, width: 6, height: 6)).fill() }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "LG Smart Touch Enabler"
        return img
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
