import XCTest
@testable import DogballWhisper

// MARK: - Fakes

final class FakeRecorder: AudioRecording {
    var levels: [Float] = [0, 0.5, 1]
    var startCount = 0
    var cancelCount = 0
    var nextResult: RecordedAudio? = RecordedAudio(
        url: URL(fileURLWithPath: "/tmp/dogball-test.wav"), duration: 2)
    var startError: Error?

    func start() throws {
        if let startError { throw startError }
        startCount += 1
    }
    func stop() -> RecordedAudio? { nextResult }
    func cancel() { cancelCount += 1 }
}

final class FakeEngine: TranscriptionEngine {
    let kind: EngineKind = .parakeet
    var isLoaded = true
    var result = "um so the thing is"
    var error: Error?
    var delay: TimeInterval = 0

    func load() async throws {}
    func unload() {}
    func transcribe(_ audioURL: URL) async throws -> String {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        return result
    }
}

final class FakeCleaner: TextCleaning {
    var result = "So the thing is."
    var error: Error?
    var delay: TimeInterval = 0
    private(set) var receivedText: String?

    func clean(_ text: String, prompt: String, model: String) async throws -> String {
        receivedText = text
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        return result
    }
}

final class FakeInserter: TextInserting {
    var outcome: InsertOutcome = .pasted
    private(set) var inserted: [String] = []

    func insert(_ text: String, targetPID: pid_t?, mode: InsertionMode) -> InsertOutcome {
        inserted.append(text)
        return outcome
    }
}

final class FakePresenter: DictationPresenting {
    private(set) var states: [DictationState] = []
    private(set) var dismissCount = 0

    func present(state: DictationState, at location: CaretLocation, levels: [Float]) {
        states.append(state)
    }
    func dismiss(after: TimeInterval) { dismissCount += 1 }
}

// MARK: - Tests

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    private var recorder: FakeRecorder!
    private var engine: FakeEngine!
    private var cleaner: FakeCleaner!
    private var inserter: FakeInserter!
    private var presenter: FakePresenter!
    private var prefs: Preferences!
    private let suiteName = "DogballWhisperTests.Coordinator"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        recorder = FakeRecorder()
        engine = FakeEngine()
        cleaner = FakeCleaner()
        inserter = FakeInserter()
        presenter = FakePresenter()
        prefs = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCoordinator(
        cleaner: TextCleaning? = nil,
        config: DictationCoordinator.Config = .init(minimumDuration: 0.3, cleanupTimeout: 0.2)
    ) -> DictationCoordinator {
        DictationCoordinator(
            recorder: recorder,
            engineProvider: { [engine] in engine },
            inserter: inserter,
            cleaner: cleaner,
            presenter: presenter,
            preferences: prefs,
            config: config
        )
    }

    /// Drives the coordinator through one press and release, waiting for the
    /// async work it kicks off on release.
    private func dictate(_ coordinator: DictationCoordinator) async {
        coordinator.handle(.began)
        coordinator.handle(.ended)
        await coordinator.waitForWork()
    }

    func testHappyPathRecordsTranscribesAndInserts() async {
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(inserter.inserted, ["um so the thing is"])
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(presenter.states.contains(.recording))
        XCTAssertTrue(presenter.states.contains(.transcribing))
    }

    func testCleanedTextIsInsertedWhenCleanupIsEnabled() async {
        let coordinator = makeCoordinator(cleaner: cleaner)
        await dictate(coordinator)

        XCTAssertEqual(cleaner.receivedText, "um so the thing is")
        XCTAssertEqual(inserter.inserted, ["So the thing is."])
        XCTAssertTrue(presenter.states.contains(.polishing))
    }

    func testCleanupIsSkippedWhenDisabled() async {
        prefs.cleanupEnabled = false
        let coordinator = makeCoordinator(cleaner: cleaner)
        await dictate(coordinator)

        XCTAssertNil(cleaner.receivedText)
        XCTAssertEqual(inserter.inserted, ["um so the thing is"])
    }

    // Cleanup must never cost the user a dictation.
    func testCleanupErrorFallsBackToTheRawTranscript() async {
        cleaner.error = URLError(.notConnectedToInternet)
        let coordinator = makeCoordinator(cleaner: cleaner)
        await dictate(coordinator)
        XCTAssertEqual(inserter.inserted, ["um so the thing is"])
    }

    func testCleanupTimeoutFallsBackToTheRawTranscript() async {
        cleaner.delay = 5
        let coordinator = makeCoordinator(cleaner: cleaner)
        await dictate(coordinator)
        XCTAssertEqual(inserter.inserted, ["um so the thing is"])
    }

    // A tap of the hotkey is not a dictation.
    func testRecordingsShorterThanTheMinimumAreDiscardedSilently() async {
        recorder.nextResult = RecordedAudio(url: URL(fileURLWithPath: "/tmp/x.wav"), duration: 0.1)
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(presenter.states.contains(where: { if case .failed = $0 { return true }; return false }))
    }

    func testCancelDiscardsTheRecordingWithoutInserting() async {
        let coordinator = makeCoordinator()
        coordinator.handle(.began)
        coordinator.handle(.cancelled)
        await coordinator.waitForWork()

        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testEmptyTranscriptShowsANoticeAndInsertsNothing() async {
        engine.result = "   "
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(presenter.states.contains(.notice("No speech")))
    }

    func testTranscriptionFailureIsSurfaced() async {
        engine.error = TranscriptionError.notLoaded
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(presenter.states.contains(where: { if case .failed = $0 { return true }; return false }))
    }

    func testMissingEngineFailsWithAnActionableMessage() async {
        let coordinator = DictationCoordinator(
            recorder: recorder,
            engineProvider: { nil },
            inserter: inserter,
            cleaner: nil,
            presenter: presenter,
            preferences: prefs,
            config: .init(minimumDuration: 0.3, cleanupTimeout: 0.2)
        )
        coordinator.handle(.began)
        await coordinator.waitForWork()

        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(
            coordinator.state,
            .failed(TranscriptionError.noModelInstalled.localizedDescription))
    }

    func testFocusChangeReportsThatTheTextWasCopiedInstead() async {
        inserter.outcome = .copiedToClipboard
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertTrue(presenter.states.contains(.notice("Copied to clipboard")))
    }

    // Escape after release abandons transcription or cleanup that is already
    // running, and does it quietly rather than as an error.
    func testAbortDuringTranscriptionInsertsNothing() async {
        engine.delay = 0.4
        let coordinator = makeCoordinator()
        coordinator.handle(.began)
        coordinator.handle(.ended)
        coordinator.abort()
        await coordinator.waitForWork()

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(
            presenter.states.contains(where: { if case .failed = $0 { return true }; return false }))
    }

    func testAbortWhileIdleDoesNothing() async {
        let coordinator = makeCoordinator()
        coordinator.abort()
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testTriggeringAgainWhileBusyIsIgnored() async {
        engine.delay = 0.2
        let coordinator = makeCoordinator()
        coordinator.handle(.began)
        coordinator.handle(.ended)
        coordinator.handle(.began)  // ignored: still transcribing
        await coordinator.waitForWork()

        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(inserter.inserted.count, 1)
    }
}
