import AppKit
import SwiftUI

/// Hosts the settings view in a normal window. An accessory app has no menu
/// bar of its own, so the window is created on demand and reused.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let preferences: Preferences
    private let models: ModelManager
    private let onHotkeyChange: (HotkeyBinding) -> Void

    init(
        preferences: Preferences,
        models: ModelManager,
        onHotkeyChange: @escaping (HotkeyBinding) -> Void
    ) {
        self.preferences = preferences
        self.models = models
        self.onHotkeyChange = onHotkeyChange
    }

    func show() {
        if window == nil {
            let view = SettingsView(
                preferences: preferences, models: models, onHotkeyChange: onHotkeyChange)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 520, height: 420),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Dogball Whisper Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
