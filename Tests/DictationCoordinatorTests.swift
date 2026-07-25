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

    /// When true, `transcribe` parks on a continuation that only
    /// `resumeUncooperativeTranscription()` can resume, and does not check
    /// `Task.isCancelled` at all — simulating a real engine whose inference
    /// call never observes cancellation. Exercises the coordinator's
    /// generation-counter recovery path, which must not depend on the
    /// engine's cooperation.
    var isUncooperative = false
    // `TranscriptionEngine` has synchronous, non-actor-isolated requirements
    // (`kind`, `isLoaded`, `unload()`), so this type can't be `@MainActor`
    // itself. Access to this property is serialized in practice: the test
    // that uses uncooperative mode polls `coordinator.state` on the main
    // actor before touching it from either side, so store/resume never
    // actually race. `nonisolated(unsafe)` records that as a deliberate,
    // manually-verified choice rather than leaving it to accidentally pass.
    nonisolated(unsafe) private var pendingContinuation: CheckedContinuation<Void, Never>?

    func load() async throws {}
    func unload() {}
    func transcribe(_ audioURL: URL) async throws -> String {
        if isUncooperative {
            await withCheckedContinuation { pendingContinuation = $0 }
        } else if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if let error { throw error }
        return result
    }

    /// Unblocks a `transcribe` call parked in uncooperative mode.
    func resumeUncooperativeTranscription() {
        pendingContinuation?.resume()
        pendingContinuation = nil
    }
}

final class FakeCleaner: TextCleaning, @unchecked Sendable {
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
        // The resting state, not just the transient presenter callback.
        XCTAssertEqual(coordinator.state, .notice("No speech"))
    }

    func testTranscriptionFailureIsSurfaced() async {
        engine.error = TranscriptionError.notLoaded
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(presenter.states.contains(where: { if case .failed = $0 { return true }; return false }))
        // The resting state, not just the transient presenter callback.
        XCTAssertEqual(coordinator.state, .failed(TranscriptionError.notLoaded.localizedDescription))
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
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    // A denied microphone (or any other recorder.start() failure) must
    // surface as a failure, not crash or hang silently.
    func testStartFailureIsSurfacedAsAFailure() async {
        struct MicDenied: LocalizedError {
            var errorDescription: String? { "Microphone access denied." }
        }
        recorder.startError = MicDenied()
        let coordinator = makeCoordinator()

        coordinator.handle(.began)
        await coordinator.waitForWork()

        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(coordinator.state, .failed("Microphone access denied."))
    }

    // A resting .failed display must not lock out the next dictation: this
    // is the one real-world scenario a first run is likely to hit (model
    // not installed yet), and it must recover without a relaunch.
    func testFailureDoesNotBlockTheNextDictation() async {
        var engineAvailable = false
        let coordinator = DictationCoordinator(
            recorder: recorder,
            engineProvider: { [engine] in engineAvailable ? engine : nil },
            inserter: inserter,
            cleaner: nil,
            presenter: presenter,
            preferences: prefs,
            config: .init(minimumDuration: 0.3, cleanupTimeout: 0.2)
        )

        coordinator.handle(.began)
        await coordinator.waitForWork()
        XCTAssertEqual(
            coordinator.state,
            .failed(TranscriptionError.noModelInstalled.localizedDescription))
        XCTAssertEqual(recorder.startCount, 0)

        engineAvailable = true
        coordinator.handle(.began)
        coordinator.handle(.ended)
        await coordinator.waitForWork()

        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(inserter.inserted.count, 1)
    }

    func testFocusChangeReportsThatTheTextWasCopiedInstead() async {
        inserter.outcome = .copiedToClipboard
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertTrue(presenter.states.contains(.notice("Copied to clipboard")))
        // The resting state, not just the transient presenter callback.
        XCTAssertEqual(coordinator.state, .notice("Copied to clipboard"))
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

    // The generation counter must recover the coordinator even when the
    // engine itself never observes cancellation — the whole premise of the
    // redesign, and previously untested since FakeEngine's delay-based mode
    // sleeps via Task.sleep, which does observe cancellation.
    func testAbortRecoversEvenWhenTheEngineNeverObservesCancellation() async {
        engine.isUncooperative = true
        let coordinator = makeCoordinator()
        coordinator.handle(.began)
        coordinator.handle(.ended)

        // Give the pipeline a moment to enter the uncooperative engine call
        // before aborting.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.state, .transcribing)

        coordinator.abort()
        XCTAssertEqual(coordinator.state, .idle)

        // The orphaned transcribe call is still parked; let it finish late
        // and prove it can neither move state nor insert text.
        engine.resumeUncooperativeTranscription()
        await coordinator.waitForWork()

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
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

    // isBusy must also hold during cleanup, not just transcription.
    func testTriggeringAgainWhileBusyDuringCleanupIsIgnored() async {
        cleaner.delay = 0.2
        let coordinator = makeCoordinator(
            cleaner: cleaner,
            config: .init(minimumDuration: 0.3, cleanupTimeout: 1))
        coordinator.handle(.began)
        coordinator.handle(.ended)

        // Give the pipeline a moment to reach .polishing before trying again.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.state, .polishing)

        coordinator.handle(.began)  // ignored: still polishing
        await coordinator.waitForWork()

        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(inserter.inserted.count, 1)
    }

    // The temp WAV must be deleted on every exit path; this proves it for
    // the ordinary success path against a file that actually exists.
    func testTempWavIsDeletedAfterASuccessfulDictation() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogball-coordinator-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data("fake audio".utf8))
        recorder.nextResult = RecordedAudio(url: url, duration: 2)

        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // The terminal-reset timer itself must actually fire, not just leave
    // begin() able to recover from a resting terminal state.
    func testTerminalStateReturnsToIdleOnItsOwnAfterTheDismissDelay() async {
        engine.result = "   "
        let coordinator = makeCoordinator(
            config: .init(minimumDuration: 0.3, cleanupTimeout: 0.2, noticeDismissDelay: 0.05))
        await dictate(coordinator)

        XCTAssertEqual(coordinator.state, .notice("No speech"))

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(coordinator.state, .idle)
    }
}
