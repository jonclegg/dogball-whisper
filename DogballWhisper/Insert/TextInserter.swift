import AppKit
import CoreGraphics

enum InsertOutcome: Equatable {
    case pasted
    case copiedToClipboard
}

protocol TextInserting {
    func insert(_ text: String, targetPID: pid_t?, mode: InsertionMode) -> InsertOutcome
}

/// Puts text on the clipboard, sends ⌘V to whatever is focused, then restores
/// the clipboard. Pasting is the only approach that works everywhere: native
/// apps, Electron, terminals, and web text fields all handle it identically.
final class PasteboardTextInserter: TextInserting {
    /// Long enough for the frontmost app to service the paste before we put the
    /// old contents back.
    static let restoreDelay: TimeInterval = 0.15

    private let virtualKeyV: CGKeyCode = 9

    func insert(_ text: String, targetPID: pid_t?, mode: InsertionMode) -> InsertOutcome {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Pasting into the wrong window is the one unrecoverable failure, so
        // bail out to a plain copy if focus moved while we were working.
        let stillFocused = targetPID == nil
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        guard mode == .paste, stillFocused, AXIsProcessTrusted() else {
            return .copiedToClipboard
        }

        postCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
            snapshot.restore(to: pasteboard)
        }
        return .pasted
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Without this, keys the user is physically holding suppress our events.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        // Set flags explicitly so a still-held modifier cannot turn this into
        // some other shortcut.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
