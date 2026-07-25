import CoreGraphics
import Foundation
import os

/// Diagnostic breadcrumbs for problems that only reproduce in real use.
///
/// Deliberately never records transcript text, cleaned text, or the API key —
/// only lengths, counts, and state names. Read them back with:
///
///     log show --last 10m --predicate 'subsystem == "com.jonclegg.DogballWhisper"'
///
/// Two levels, and the split matters. `log` is for failures and refusals: a
/// handful of lines that only appear when something went wrong, which is what
/// a user needs when they come to report it. `verbose` is per-dictation
/// detail — caret coordinates, character counts, timings — and is off unless
/// the user turns it on, because at `notice` with `.public` these persist to
/// the system log store for days, and a line per dictation is a durable
/// record of when someone dictated, how much they said, and where their
/// cursor was. That is not something a dictation app should keep about
/// everyone by default.
enum Diagnostics {
    private static let logger = Logger(
        subsystem: "com.jonclegg.DogballWhisper", category: "dictation")

    private static let insertSequence = OSAllocatedUnfairLock(initialState: 0)

    /// Turn per-dictation logging on with
    /// `defaults write com.jonclegg.DogballWhisper verboseDiagnostics -bool YES`
    /// and relaunch; off again with `-bool NO`.
    static let verboseDefaultsKey = "verboseDiagnostics"

    /// Read once per launch rather than per line: `defaults write` on a
    /// running app is not reliably observed anyway, so a relaunch is part of
    /// turning this on either way, and this keeps the hot path free of
    /// repeated lookups.
    private static let isVerbose = UserDefaults.standard.bool(forKey: verboseDefaultsKey)

    /// Failures and refusals only. Anything logged here is kept in every
    /// build, so it has to be worth persisting about a user who never asked
    /// for diagnostics.
    static func log(_ message: String) {
        // `notice`, not `info`, on purpose. Info-level messages live only in
        // an in-memory ring buffer and are not written to the log store, so
        // `log show` finds them for a few minutes and then reports nothing at
        // all — which is indistinguishable from the code never having run.
        // Notice is persisted, and none of this is chatty enough to matter.
        logger.notice("\(message, privacy: .public)")
    }

    /// Per-dictation detail, off unless `verboseDefaultsKey` is set. The
    /// message is an autoclosure so the string interpolation does not run at
    /// all in the shipped default.
    static func verbose(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        log(message())
    }

    /// How an error may be written to the log: its shape, never a body.
    /// `PolishError.http` carries up to 300 bytes of the provider's response,
    /// and providers echo the submitted text back in moderation rejections,
    /// so `localizedDescription` here would be a route from transcript to
    /// system log.
    static func describe(_ error: Error) -> String {
        switch error {
        case let polish as PolishError:
            switch polish {
            case .missingAPIKey: return "no API key"
            case .emptyResponse: return "empty response"
            case let .http(status, _): return "HTTP \(status)"
            case .requiresReasoning: return "model mandates reasoning"
            }
        case let urlError as URLError:
            return "URLError \(urlError.code.rawValue)"
        default:
            return String(describing: type(of: error))
        }
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
