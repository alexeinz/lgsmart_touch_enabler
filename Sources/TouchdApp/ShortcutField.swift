import AppKit
import SwiftUI
import TouchCore

/// A button that records the next key combination the user presses.
struct ShortcutField: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(recording ? "Press keys…" : shortcut.displayString)
                    .frame(minWidth: 110)
                    .foregroundStyle(recording ? Color.accentColor : (shortcut.isDisabled ? .secondary : .primary))
            }
            .buttonStyle(.bordered)

            Menu {
                ForEach(Array(Shortcut.presets.enumerated()), id: \.offset) { _, p in
                    Button(p.name) { shortcut = p.shortcut }
                }
            } label: { Image(systemName: "list.bullet") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose a preset")
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop(); return nil               // Esc cancels
            }
            shortcut = Shortcut(keyCode: event.keyCode, flags: Self.cgFlags(event.modifierFlags))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    static func cgFlags(_ f: NSEvent.ModifierFlags) -> CGEventFlags {
        var r: CGEventFlags = []
        if f.contains(.control) { r.insert(.maskControl) }
        if f.contains(.option) { r.insert(.maskAlternate) }
        if f.contains(.shift) { r.insert(.maskShift) }
        if f.contains(.command) { r.insert(.maskCommand) }
        if f.contains(.function) { r.insert(.maskSecondaryFn) }   // arrow / F-keys report fn, as real events do
        return r
    }
}
