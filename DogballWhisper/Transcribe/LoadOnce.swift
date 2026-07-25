import Foundation

/// Runs an async throwing operation at most once at a time, letting
/// concurrent callers await the same in-flight (or already-completed) run
/// instead of starting another.
///
/// Engines with real setup cost (model download + load) use this so `load()`
/// is safe to call from more than one place at once — e.g. the dictation
/// coordinator and the settings model manager both call it — without racing
/// two downloads onto the same partial file on disk.
///
/// A successful run is cached forever, so later calls are free. A failed run
/// is *not* cached: the next call retries from scratch, because the likely
/// failure here is a network drop mid-download, not a permanent condition.
actor LoadOnce<Success: Sendable> {
    private var inFlight: Task<Success, Error>?
    private var cachedResult: Success?

    init() {}

    /// Runs `operation` unless a previous call already succeeded, in which
    /// case the cached result is returned immediately. Calls that arrive
    /// while `operation` is still running await that same run.
    func run(_ operation: @escaping @Sendable () async throws -> Success) async throws -> Success {
        if let cachedResult {
            return cachedResult
        }
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task { try await operation() }
        inFlight = task
        do {
            let result = try await task.value
            cachedResult = result
            inFlight = nil
            return result
        } catch {
            inFlight = nil
            throw error
        }
    }
}
