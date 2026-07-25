import AppKit

/// The status-bar item: the app's only persistent UI.
@MainActor
final class MenuBarController: NSObject {
    let statusItem: NSStatusItem

    private let onOpenSettings: () -> Void
    private let onFinishSetup: () -> Void
    private let activeModelItem = NSMenuItem(title: "No model installed", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(
        title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    /// Only visible while first-run setup is incomplete. See `setSetupIncomplete`.
    private let finishSetupItem = NSMenuItem(
        title: "Finish setup…", action: #selector(finishSetupTapped), keyEquivalent: "")
    private let finishSetupSeparator = NSMenuItem.separator()

    init(onOpenSettings: @escaping () -> Void, onFinishSetup: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onFinishSetup = onFinishSetup
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "mic", accessibilityDescription: "Dogball Whisper")

        let menu = NSMenu()
        finishSetupItem.target = self
        finishSetupItem.isHidden = true
        finishSetupSeparator.isHidden = true
        menu.addItem(finishSetupItem)
        menu.addItem(finishSetupSeparator)

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
        statusItem.button?.contentTintColor = state == .recording ? .systemBlue : nil
    }

    func setActiveModelName(_ name: String?) {
        activeModelItem.title = name ?? "No model installed"
    }

    /// Shown only while first-run setup is incomplete (permissions or the
    /// model still missing), so a user who dismisses the setup window with
    /// the titlebar close button has a way back in without quitting and
    /// relaunching. Call with `false` once onboarding finishes; nothing
    /// re-shows it afterward for the life of the process.
    func setSetupIncomplete(_ incomplete: Bool) {
        finishSetupItem.isHidden = !incomplete
        finishSetupSeparator.isHidden = !incomplete
    }

    /// Re-reads `LoginItem.isEnabled` rather than trusting a value passed
    /// in, so the checkmark always reflects actual system state — including
    /// a change made from the settings window, or from System Settings
    /// directly — not whatever this controller last cached.
    func refreshLaunchAtLoginState() {
        launchAtLoginItem.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func finishSetupTapped() {
        onFinishSetup()
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        launchAtLoginItem.state = LoginItem.isEnabled ? .on : .off
    }
}
