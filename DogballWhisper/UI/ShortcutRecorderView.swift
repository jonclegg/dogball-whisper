import AppKit
import SwiftUI

/// Captures a custom modifier+key combo. Uses a local NSEvent monitor rather
/// than the global tap: this only needs to see events while the settings window
/// is focused, so it needs no extra permission.
struct ShortcutRecorderView: View {
    @Binding var binding: HotkeyBinding
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "Press a key combination…" : binding.displayName) {
            isRecording ? stop() : start()
        }
        .buttonStyle(.bordered)
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                .intersection(HotkeyMatcher.relevantMasks)
            // Escape abandons recording; a bare key is not a usable global hotkey.
            if event.keyCode == 53 {
                stop()
                return nil
            }
            guard !flags.isEmpty else { return nil }
            binding = HotkeyBinding(comboKeyCode: event.keyCode, modifiers: flags)
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
