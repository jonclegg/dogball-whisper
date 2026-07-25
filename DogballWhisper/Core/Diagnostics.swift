import CoreGraphics
import Foundation
import os

/// Diagnostic breadcrumbs for problems that only reproduce in real use.
///
/// Deliberately never records transcript text, cleaned text, or the API key —
/// only lengths, counts, and state names. Read them back with:
///
///     log show --last 10m --predicate 'subsystem == "com.jonclegg.DogballWhisper"'
enum Diagnostics {
    private static let logger = Logger(
        subsystem: "com.jonclegg.DogballWhisper", category: "dictation")

    private static let insertSequence = OSAllocatedUnfairLock(initialState: 0)

    static func log(_ message: String) {
        // `notice`, not `info`, on purpose. Info-level messages live only in
        // an in-memory ring buffer and are not written to the log store, so
        // `log show` finds them for a few minutes and then reports nothing at
        // all — which is indistinguishable from the code never having run.
        // Notice is persisted, and none of this is chatty enough to matter.
        logger.notice("\(message, privacy: .public)")
    }

    /// Rect geometry as a compact string. Coordinates and sizes only — a rect
    /// says where a caret is, never what was typed into it.
    static func describe(_ rect: CGRect) -> String {
        String(
            format: "x=%.0f y=%.0f w=%.1f h=%.1f",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    /// Monotonic count of insertions attempted this launch. If one dictation
    /// produces two inserts, this is what proves it.
    static func nextInsertSequence() -> Int {
        insertSequence.withLock { count in
            count += 1
            return count
        }
    }
}
