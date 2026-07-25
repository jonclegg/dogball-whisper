import Foundation

/// Runs an async throwing operation at most once *at a time*, letting
/// concurrent callers await the same in-flight run instead of starting
/// another.
///
/// Engines with real setup cost (model download + load) use this so `load()`
/// is safe to call from more than one place at once — e.g. the dictation
/// coordinator and the settings model manager both call it — without racing
/// two downloads onto the same partial file on disk.
///
/// `LoadOnce` only coalesces concurrent calls; it does not remember whether a
/// past run succeeded. Callers that want "free after the first success"
/// behavior track that themselves (e.g. `ParakeetEngine`'s `isLoaded` flag),
/// because only the caller knows when that memory should be invalidated —
/// here, when `unload()` frees the model. If `LoadOnce` cached success
/// itself, `unload()` would have no way to clear it, and a later `load()`
/// would hand back a stale, already-freed result instead of actually
/// reloading.
actor LoadOnce<Success: Sendable> {
    private var inFlight: Task<Success, Error>?

    init() {}

    /// Runs `operation`, or, if a previous call is still running it, awaits
    /// that same in-flight run instead of starting a second one. Once the
    /// run finishes (success or failure) it is forgotten, so the next call
    /// — whether concurrent-but-later or well after the fact — runs
    /// `operation` again.
    func run(_ operation: @escaping @Sendable () async throws -> Success) async throws -> Success {
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
