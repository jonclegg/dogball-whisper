import AppKit
import Observation

@main
enum DogballWhisperMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var models = ModelManager(preferences: preferences)

    private var menuBar: MenuBarController?
    private var panel: DictationPanelController?
    private var recorder: AudioRecorder?
    private var coordinator: DictationCoordinator?
    private var monitor: HotkeyMonitor?
    private var settings: SettingsWindowController?
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = DictationPanelController()
        self.panel = panel

        let recorder = AudioRecorder(onLevels: { levels in
            MainActor.assumeIsolated { panel.updateLevels(levels) }
        })
        self.recorder = recorder

        let coordinator = DictationCoordinator(
            recorder: recorder,
            engineProvider: { [weak self] in self?.models.activeEngine },
            inserter: PasteboardTextInserter(),
            cleaner: PolishService(),
            presenter: panel,
            preferences: preferences
        )
        self.coordinator = coordinator

        // Chromium and Electron apps only build an accessibility tree once
        // something asks them to. Asking when they are activated means the
        // tree is ready long before the dictation key is pressed, instead of
        // that work sitting between the key press and the microphone.
        CaretLocator.startObservingAppSwitches()

        installEditMenu()

        let menuBar = MenuBarController(
            onOpenSettings: { [weak self] in self?.showSettings() },
            onFinishSetup: { [weak self] in self?.showOnboarding() }
        )
        self.menuBar = menuBar
        refreshActiveModelLabel()
        // ModelManager is @Observable but its `activeModelID` is a computed
        // pass-through over `preferences` (not itself tracked), so this
        // observes `activeEngine` instead — a stored property that always
        // changes in lockstep with `preferences.activeModelID` (see the
        // invariant documented on ModelManager.makeActive). That keeps the
        // menu's model name current after Settings > Models install/use/
        // delete, not just at launch.
        observeActiveModel()
        coordinator.onStateChange = { [weak menuBar] state in menuBar?.update(state: state) }

        let monitor = HotkeyMonitor(binding: preferences.hotkeyBinding) { signal in
            MainActor.assumeIsolated { coordinator.handle(signal) }
        }
        monitor.onEscape = { MainActor.assumeIsolated { coordinator.abort() } }
        self.monitor = monitor

        let readyToLaunch = preferences.hasCompletedOnboarding && Permissions.allRequiredGranted
        menuBar.setSetupIncomplete(!readyToLaunch)
        if readyToLaunch {
            startMonitoring()
            // A returning launch already has mic access, so there is no
            // permission prompt risk here. `prewarm()` itself checks
            // authorization again and does its hardware work off the main
            // thread, so this does not delay the rest of launch.
            recorder.prewarm()
            Task {
                await models.loadActiveEngine()
                refreshActiveModelLabel()
            }
        } else {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(
                preferences: preferences,
                models: models,
                onHotkeyChange: { [weak self] binding in self?.monitor?.binding = binding },
                onFinished: { [weak self] in
                    guard let self else { return }
                    self.preferences.hasCompletedOnboarding = true
                    self.menuBar?.setSetupIncomplete(false)
                    self.startMonitoring()
                    // Mic permission was just granted as part of finishing
                    // setup, so this is the first moment pre-warming can
                    // actually do anything for a fresh install.
                    self.recorder?.prewarm()
                    Task {
                        await self.models.loadActiveEngine()
                        self.refreshActiveModelLabel()
                    }
                }
            )
        }
        // Idempotent: OnboardingWindowController.show() only builds the window
        // once and otherwise just brings the existing one forward, and its
        // poller's start() no-ops while already running. Safe to call again
        // from the "Finish setup…" menu item while the window is already open.
        onboarding?.show()
    }

    private func refreshActiveModelLabel() {
        menuBar?.setActiveModelName(
            preferences.activeModelID.flatMap { ModelCatalog.descriptor(id: $0)?.name })
    }

    private func observeActiveModel() {
        withObservationTracking {
            _ = models.activeEngine
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshActiveModelLabel()
                // withObservationTracking's onChange fires once and then
                // stops; re-register to keep observing every subsequent
                // change for the lifetime of the app.
                self.observeActiveModel()
            }
        }
    }

    /// An accessory app has no menu bar of its own, and macOS routes ⌘X/⌘C/⌘V
    /// through a menu's key equivalents — so without this, paste simply does
    /// nothing in every text field the app shows, including the API key fields
    /// in onboarding and settings. The menu is never drawn anywhere; it exists
    /// purely so the standard editing shortcuts reach the first responder.
    private func installEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(
            withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select all", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = editMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func startMonitoring() {
        do {
            try monitor?.start()
        } catch {
            NSLog("Hotkey monitor failed: \(error.localizedDescription)")
        }
    }

    private func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(
                preferences: preferences,
                models: models,
                onHotkeyChange: { [weak self] binding in self?.monitor?.binding = binding },
                onLaunchAtLoginChange: { [weak self] in self?.menuBar?.refreshLaunchAtLoginState() }
            )
        }
        settings?.show()
    }

}
