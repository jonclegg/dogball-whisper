import Foundation

struct TimedOutError: Error {}

/// Runs `operation`, giving up after `seconds`.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimedOutError()
        }
        guard let result = try await group.next() else { throw TimedOutError() }
        group.cancelAll()
        return result
    }
}
