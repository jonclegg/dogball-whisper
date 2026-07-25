import AppKit

/// Owns the status-bar item. Task 7 gives it live dictation state.
@MainActor
final class MenuBarController {
    let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "mic",
            accessibilityDescription: "Dogball Whisper"
        )

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit Dogball Whisper",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
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
    }
}
