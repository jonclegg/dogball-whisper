import AppKit

/// The status-bar item: the app's only persistent UI.
@MainActor
final class MenuBarController: NSObject {
    let statusItem: NSStatusItem

    private let onOpenSettings: () -> Void
    private let activeModelItem = NSMenuItem(title: "No model installed", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(
        title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "mic", accessibilityDescription: "Dogball Whisper")

        let menu = NSMenu()
        activeModelItem.isEnabled = false
        menu.addItem(activeModelItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        launchAtLoginItem.target = self
        launchAtLoginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Dogball Whisper",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        statusItem.menu = menu
    }

    func update(state: DictationState) {
        let symbol: String
        switch state {
        case .idle, .notice: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .transcribing, .polishing: symbol = "waveform"
        case .failed: symbol = "exclamationmark.triangle"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Dogball Whisper")
        statusItem.button?.contentTintColor = state == .recording ? .systemRed : nil
    }

    func setActiveModelName(_ name: String?) {
        activeModelItem.title = name ?? "No model installed"
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        launchAtLoginItem.state = LoginItem.isEnabled ? .on : .off
    }
}
