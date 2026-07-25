import AppKit
import Foundation

enum DictationState: Equatable {
    case idle
    case recording
    case transcribing
    case polishing
    /// Something went wrong; the message is shown in the panel.
    case failed(String)
    /// Nothing went wrong but there is something to say ("No speech").
    case notice(String)
}

protocol TextCleaning {
    func clean(_ text: String, prompt: String, model: String) async throws -> String
}

protocol DictationPresenting: AnyObject {
    func present(state: DictationState, at location: CaretLocation, levels: [Float])
    func dismiss(after: TimeInterval)
}

typealias EngineProvider = () -> TranscriptionEngine?

/// The single stateful component: turns hotkey signals into recorded audio,
/// text, and a paste. Everything it touches is a protocol so the whole state
/// machine runs in tests without a mic, a model, or a keyboard.
@MainActor
final class DictationCoordinator {
    struct Config {
        var minimumDuration: TimeInterval = 0.3
        var cleanupTimeout: TimeInterval = 3
        var noticeDismissDelay: TimeInterval = 1.5
    }

    private(set) var state: DictationState = .idle {
        didSet {
            guard state != oldValue else { return }
            presenter.present(state: state, at: location, levels: recorder.levels)
            onStateChange?(state)
        }
    }

    var onStateChange: ((DictationState) -> Void)?

    private let recorder: AudioRecording
    private let engineProvider: EngineProvider
    private let inserter: TextInserting
    private let cleaner: TextCleaning?
    private let presenter: DictationPresenting
    private let preferences: Preferences
    private let config: Config

    private var location: CaretLocation = .unknown
    private var work: Task<Void, Never>?

    init(
        recorder: AudioRecording,
        engineProvider: @escaping EngineProvider,
        inserter: TextInserting,
        cleaner: TextCleaning?,
        presenter: DictationPresenting,
        preferences: Preferences,
        config: Config = Config()
    ) {
        self.recorder = recorder
        self.engineProvider = engineProvider
        self.inserter = inserter
        self.cleaner = cleaner
        self.presenter = presenter
        self.preferences = preferences
        self.config = config
    }

    func handle(_ signal: HotkeySignal) {
        switch signal {
        case .began: begin()
        case .ended: end()
        case .cancelled: cancel()
        }
    }

    /// Escape after release: give up on transcription or cleanup already in
    /// flight. Nothing is inserted and nothing is reported as an error.
    func abort() {
        switch state {
        case .transcribing, .polishing:
            work?.cancel()
        case .recording:
            cancel()
        case .idle, .failed, .notice:
            break
        }
    }

    /// Test hook: awaits whatever asynchronous work the last signal started.
    func waitForWork() async {
        await work?.value
    }

    /// `.failed`/`.notice` are informational, not busy: the coordinator is
    /// free to start a new dictation while one is being displayed.
    private var isBusy: Bool {
        switch state {
        case .recording, .transcribing, .polishing: return true
        case .idle, .failed, .notice: return false
        }
    }

    private func begin() {
        // A prior failure or notice is a resting, non-busy display, not a
        // lock: only active recording/transcription/cleanup should block a
        // fresh press. Requiring exact `.idle` here would leave the
        // coordinator stuck after the first error until something else
        // reset it, since `fail`/`notice` no longer force a synchronous
        // return to `.idle` (that reset would race the very presenter
        // display the state was set for).
        guard !isBusy else { return }
        guard engineProvider() != nil else {
            fail(TranscriptionError.noModelInstalled.localizedDescription)
            return
        }
        location = CaretLocator.current()
        do {
            try recorder.start()
            state = .recording
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func cancel() {
        guard state == .recording else { return }
        recorder.cancel()
        state = .idle
        presenter.dismiss(after: 0)
    }

    private func end() {
        guard state == .recording else { return }
        guard let audio = recorder.stop() else {
            state = .idle
            presenter.dismiss(after: 0)
            return
        }

        // Too short to be speech: the user tapped the key by accident.
        guard audio.duration >= config.minimumDuration else {
            try? FileManager.default.removeItem(at: audio.url)
            state = .idle
            presenter.dismiss(after: 0)
            return
        }

        state = .transcribing
        work = Task { [weak self] in
            await self?.finish(audio: audio)
        }
    }

    private func finish(audio: RecordedAudio) async {
        defer { try? FileManager.default.removeItem(at: audio.url) }

        guard let engine = engineProvider() else {
            fail(TranscriptionError.noModelInstalled.localizedDescription)
            return
        }

        let transcript: String
        do {
            if !engine.isLoaded { try await engine.load() }
            transcript = try await engine.transcribe(audio.url)
        } catch is CancellationError {
            abandon()
            return
        } catch {
            if Task.isCancelled {
                abandon()
            } else {
                fail(error.localizedDescription)
            }
            return
        }

        guard !Task.isCancelled else {
            abandon()
            return
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice("No speech")
            return
        }

        let finalText = await cleanIfEnabled(trimmed)

        // One last check: aborting during cleanup must not paste anything.
        guard !Task.isCancelled else {
            abandon()
            return
        }

        let outcome = inserter.insert(
            finalText, targetPID: location.pid, mode: preferences.insertionMode)

        switch outcome {
        case .pasted:
            state = .idle
            presenter.dismiss(after: 0)
        case .copiedToClipboard:
            notice("Copied to clipboard")
        }
    }

    /// Cleanup is best-effort by design: any failure, timeout, or missing key
    /// falls through to the raw transcript rather than losing the dictation.
    private func cleanIfEnabled(_ text: String) async -> String {
        guard preferences.cleanupEnabled, let cleaner else { return text }
        state = .polishing
        let prompt = preferences.cleanupPrompt
        let model = preferences.cleanupModelID
        do {
            return try await withTimeout(seconds: config.cleanupTimeout) {
                try await cleaner.clean(text, prompt: prompt, model: model)
            }
        } catch {
            return text
        }
    }

    /// The user asked to stop, so this is not a failure worth reporting.
    private func abandon() {
        state = .idle
        presenter.dismiss(after: 0)
    }

    /// Leaves `state` at `.failed` so the caller (and tests) can observe it;
    /// `begin()` treats it as non-busy, so the next press starts cleanly
    /// without needing a synchronous, racy reset back to `.idle` here.
    private func fail(_ message: String) {
        state = .failed(message)
        presenter.dismiss(after: config.noticeDismissDelay)
    }

    /// See `fail(_:)`: leaves `state` at `.notice` rather than forcing it
    /// back to `.idle` synchronously.
    private func notice(_ message: String) {
        state = .notice(message)
        presenter.dismiss(after: config.noticeDismissDelay)
    }
}

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
