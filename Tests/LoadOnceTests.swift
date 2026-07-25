import XCTest
@testable import DogballWhisper

final class LoadOnceTests: XCTestCase {

    /// Thread-safe call counter for the tests below.
    private actor Counter {
        private(set) var count = 0

        @discardableResult
        func increment() -> Int {
            count += 1
            return count
        }
    }

    func testConcurrentCallsRunTheOperationExactlyOnceAndAllCallersSeeTheResult() async throws {
        let counter = Counter()
        let loadOnce = LoadOnce<Int>()

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await loadOnce.run {
                        // Give overlapping calls room to actually arrive
                        // while the first run is still in flight.
                        try await Task.sleep(nanoseconds: 20_000_000)
                        return await counter.increment()
                    }
                }
            }
            var collected: [Int] = []
            for try await value in group {
                collected.append(value)
            }
            return collected
        }

        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(
            results.allSatisfy { $0 == 1 },
            "every caller should see the single run's result, got: \(results)")
        let finalCount = await counter.count
        XCTAssertEqual(finalCount, 1, "operation should have run exactly once")
    }

    func testSuccessIsCachedSoALaterCallDoesNotRerun() async throws {
        let counter = Counter()
        let loadOnce = LoadOnce<Int>()

        let first = try await loadOnce.run { await counter.increment() }
        let second = try await loadOnce.run { await counter.increment() }

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1, "second call should reuse the cached result")
        let finalCount = await counter.count
        XCTAssertEqual(finalCount, 1)
    }

    func testFailureIsNotCachedSoALaterCallRetries() async throws {
        struct BoomError: Error {}
        let attempts = Counter()
        let loadOnce = LoadOnce<Int>()

        do {
            _ = try await loadOnce.run {
                await attempts.increment()
                throw BoomError()
            }
            XCTFail("expected the first call to throw")
        } catch is BoomError {
            // expected
        }

        let result = try await loadOnce.run {
            await attempts.increment()
        }

        XCTAssertEqual(result, 2, "second call should have re-run the operation")
        let finalCount = await attempts.count
        XCTAssertEqual(finalCount, 2)
    }

    func testConcurrentCallersDuringAFailingRunAllSeeTheFailureAndRunOnce() async throws {
        struct BoomError: Error, Equatable {}
        let attempts = Counter()
        let loadOnce = LoadOnce<Int>()

        let outcomes = await withTaskGroup(of: Result<Int, Error>.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        let value = try await loadOnce.run {
                            try await Task.sleep(nanoseconds: 20_000_000)
                            await attempts.increment()
                            throw BoomError()
                        }
                        return .success(value)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<Int, Error>] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        XCTAssertEqual(outcomes.count, 5)
        XCTAssertTrue(
            outcomes.allSatisfy {
                if case .failure(let error) = $0 { return error is BoomError }
                return false
            },
            "every caller should see the failure")
        let finalCount = await attempts.count
        XCTAssertEqual(finalCount, 1, "operation should have run exactly once even though it failed")
    }
}
