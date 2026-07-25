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

    /// The delayed restore from the most recent `insert()` call, so a second
    /// dictation started within `restoreDelay` can supersede it instead of
    /// letting two restores interleave.
    private var pendingRestore: DispatchWorkItem?

    func insert(_ text: String, targetPID: pid_t?, mode: InsertionMode) -> InsertOutcome {
        pendingRestore?.cancel()

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let writeChangeCount = pasteboard.changeCount

        // Pasting into the wrong window is the one unrecoverable failure, so
        // bail out to a plain copy if focus moved while we were working.
        // targetPID is nil when the caller had no target to gate on (there is
        // nothing to compare against, so there is nothing to protect against);
        // callers that care about this always pass the PID captured when
        // recording started. Do not turn a nil PID into a refusal to paste.
        let stillFocused = targetPID == nil
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        guard mode == .paste, stillFocused, AXIsProcessTrusted() else {
            return .copiedToClipboard
        }

        Diagnostics.log("paste: posting command-V for \(text.count) characters")
        postCommandV()
        let restore = DispatchWorkItem { [weak self] in
            self?.pendingRestore = nil
            // Only restore if nothing else has touched the pasteboard since we
            // wrote the dictated text: someone pressing Cmd-C, or a second
            // dictation landing before this one's delay elapsed, both mean the
            // pasteboard now belongs to something else and must be left alone.
            guard Self.shouldRestore(
                currentChangeCount: pasteboard.changeCount,
                expectedChangeCount: writeChangeCount
            ) else { return }
            snapshot.restore(to: pasteboard)
        }
        pendingRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: restore)
        return .pasted
    }

    /// Whether a delayed restore should still apply. Extracted as a pure
    /// function so the gating logic is unit-testable without posting real
    /// keyboard events or touching a live pasteboard.
    static func shouldRestore(currentChangeCount: Int, expectedChangeCount: Int) -> Bool {
        currentChangeCount == expectedChangeCount
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
