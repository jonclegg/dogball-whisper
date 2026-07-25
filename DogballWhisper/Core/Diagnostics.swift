import Foundation
import os

/// Diagnostic breadcrumbs for problems that only reproduce in real use.
///
/// Deliberately never records transcript text, cleaned text, or the API key —
/// only lengths, counts, and state names. Read them back with:
///
///     log show --last 10m --predicate 'subsystem == "com.jonclegg.DogballWhisper"' --info
enum Diagnostics {
    private static let logger = Logger(
        subsystem: "com.jonclegg.DogballWhisper", category: "dictation")

    private static let insertSequence = OSAllocatedUnfairLock(initialState: 0)

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
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
