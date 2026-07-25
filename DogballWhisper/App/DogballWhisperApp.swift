import AppKit

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
    private var coordinator: DictationCoordinator?
    private var monitor: HotkeyMonitor?
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = DictationPanelController()
        self.panel = panel

        let recorder = AudioRecorder(onLevels: { levels in
            MainActor.assumeIsolated { panel.updateLevels(levels) }
        })

        let coordinator = DictationCoordinator(
            recorder: recorder,
            engineProvider: { [weak self] in self?.models.activeEngine },
            inserter: PasteboardTextInserter(),
            cleaner: PolishService(),
            presenter: panel,
            preferences: preferences
        )
        self.coordinator = coordinator

        let menuBar = MenuBarController(onOpenSettings: { [weak self] in self?.showSettings() })
        menuBar.setActiveModelName(
            preferences.activeModelID.flatMap { ModelCatalog.descriptor(id: $0)?.name })
        self.menuBar = menuBar
        coordinator.onStateChange = { [weak menuBar] state in menuBar?.update(state: state) }

        let monitor = HotkeyMonitor(binding: preferences.hotkeyBinding) { signal in
            MainActor.assumeIsolated { coordinator.handle(signal) }
        }
        monitor.onEscape = { MainActor.assumeIsolated { coordinator.abort() } }
        self.monitor = monitor

        // Task 12 puts onboarding in front of this.
        startMonitoring()
        Task {
            await models.loadActiveEngine()
            menuBar.setActiveModelName(
                preferences.activeModelID.flatMap { ModelCatalog.descriptor(id: $0)?.name })
        }
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
                onHotkeyChange: { [weak self] binding in self?.monitor?.binding = binding }
            )
        }
        settings?.show()
    }

}
