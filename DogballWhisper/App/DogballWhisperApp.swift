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
    private var menuBar: MenuBarController?
    private var coordinator: DictationCoordinator?
    private var monitor: HotkeyMonitor?
    private var engine: TranscriptionEngine?
    private var panel: DictationPanelController?
    private let preferences = Preferences()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController()
        self.menuBar = menuBar

        let engine = ParakeetEngine()
        self.engine = engine

        let panel = DictationPanelController()
        self.panel = panel

        let recorder = AudioRecorder(onLevels: { levels in
            MainActor.assumeIsolated { panel.updateLevels(levels) }
        })

        let coordinator = DictationCoordinator(
            recorder: recorder,
            engineProvider: { [weak self] in self?.engine },
            inserter: PasteboardTextInserter(),
            cleaner: nil,
            presenter: panel,
            preferences: preferences
        )
        coordinator.onStateChange = { [weak menuBar] state in
            menuBar?.update(state: state)
        }
        self.coordinator = coordinator

        let monitor = HotkeyMonitor(binding: preferences.hotkeyBinding) { signal in
            MainActor.assumeIsolated { coordinator.handle(signal) }
        }
        monitor.onEscape = { MainActor.assumeIsolated { coordinator.abort() } }
        self.monitor = monitor
        do {
            try monitor.start()
        } catch {
            NSLog("Hotkey monitor failed: \(error.localizedDescription)")
        }

        // Load the model up front so the first dictation is not slow.
        Task { try? await engine.load() }
    }
}
