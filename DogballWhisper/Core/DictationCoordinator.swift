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

/// Runs off the main actor (a task-group child inside `cleanIfEnabled`), so
/// a conforming type must be safe to invoke from another isolation domain.
protocol TextCleaning: Sendable {
    func clean(_ text: String, prompt: String, model: String) async throws -> String
}

@MainActor
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

    /// Identifies the in-flight `finish()` pipeline. `abort()` bumps this
    /// whenever it gives up on transcription/cleanup, so a `finish()` that
    /// resumes later — because the engine never observed cancellation, for
    /// instance — can tell it is an orphan and touch nothing rather than
    /// racing whatever pipeline has started since.
    private var generation = 0

    /// The task, if any, that will return a resting `.failed`/`.notice`
    /// state to `.idle` after the presenter's own dismiss delay.
    private var terminalResetTask: Task<Void, Never>?

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
    ///
    /// Recovery cannot wait on the engine or cleaner cooperating with
    /// cancellation — a hung `transcribe` call may never observe it — so
    /// this resets the UI immediately instead of leaving that to whatever
    /// `finish()` eventually notices. Bumping `generation` here is what lets
    /// a late-resuming `finish()` recognize it is stale.
    func abort() {
        switch state {
        case .transcribing, .polishing:
            // Invariant `finish()` relies on: cancellation and generation
            // invalidation always happen together, from this one call site.
            // That is what lets `finish()` treat `isCurrent(token)` alone as
            // sufficient — see the guard at the top of `finish()`. A future
            // stop-everything path must preserve this pairing rather than
            // calling `work?.cancel()` on its own.
            generation += 1
            work?.cancel()
            abandon()
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
        // A fresh press supersedes whatever resting failure/notice is being
        // shown; nothing should reset state out from under the dictation
        // that is about to start.
        terminalResetTask?.cancel()

        // Force a real transition through .idle first. Without this, a
        // second press that fails identically to the first (e.g. two
        // presses in a row with no model installed) would set the exact
        // same `.failed(message)` value again; the `didSet` equality guard
        // would then suppress `present()` even though `dismiss(after:)`
        // still fires, leaving the user with a dismiss timer and no
        // display to dismiss.
        switch state {
        case .failed, .notice: state = .idle
        case .idle, .recording, .transcribing, .polishing: break
        }

        // A prior failure or notice is a resting, non-busy display, not a
        // lock: only active recording/transcription/cleanup should block a
        // fresh press. Requiring exact `.idle` here would leave the
        // coordinator stuck after the first error until the terminal-reset
        // timer got around to firing.
        guard !isBusy else { return }

        location = CaretLocator.current()
        // Dictated text is sent to OpenRouter for cleanup, so recording into
        // a password field would ship the password to a third party. This
        // gate runs before the engine-availability check below on purpose:
        // no dictation may start here no matter what else is true.
        guard !location.isSecureField else {
            notice("Not in a password field")
            return
        }
        guard engineProvider() != nil else {
            fail(TranscriptionError.noModelInstalled.localizedDescription)
            return
        }
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

        generation += 1
        let token = generation
        state = .transcribing
        work = Task { [weak self] in
            await self?.finish(audio: audio, token: token)
        }
    }

    private func finish(audio: RecordedAudio, token: Int) async {
        defer { try? FileManager.default.removeItem(at: audio.url) }

        // Covers cancellation observed before the engine's first suspension
        // point (esc pressed between `end()` and the first `await`): abort()
        // always bumps `generation` in the same call that cancels the task
        // (see the comment there), so the token check alone is sufficient —
        // a separate `Task.isCancelled` check would be redundant with it as
        // long as that pairing holds.
        guard isCurrent(token) else { return }

        guard let engine = engineProvider() else {
            fail(TranscriptionError.noModelInstalled.localizedDescription)
            return
        }

        let transcript: String
        do {
            if !engine.isLoaded { try await engine.load() }
            transcript = try await engine.transcribe(audio.url)
        } catch {
            // A stale pipeline (superseded or aborted while awaiting the
            // engine) must not report a failure for work nobody asked to
            // see the result of anymore; `abort()` already handled the UI.
            guard isCurrent(token) else { return }
            fail(error.localizedDescription)
            return
        }

        guard isCurrent(token) else { return }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice("No speech")
            return
        }

        let finalText = await cleanIfEnabled(trimmed, token: token)

        // One last check: aborting during cleanup, or a new pipeline having
        // started since, must not paste anything.
        guard isCurrent(token) else { return }

        // Lengths and counts only, never the text itself: this is here to
        // locate a duplicated-insertion bug, and a dictation app has no
        // business writing what you said into the system log. A cleaned length
        // near twice the raw length points at the cleanup model; equal lengths
        // with doubled text on screen point at the paste being delivered twice.
        Diagnostics.log(
            "dictation \(token): raw=\(trimmed.count) final=\(finalText.count) insert#\(Diagnostics.nextInsertSequence())")

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

    /// Whether `token` still names the current pipeline. False once a new
    /// dictation has started or `abort()` has given up on this one.
    private func isCurrent(_ token: Int) -> Bool { token == generation }

    /// Cleanup is best-effort by design: any failure, timeout, or missing key
    /// falls through to the raw transcript rather than losing the dictation.
    ///
    /// Guards `token` itself before writing `.polishing`: today there is no
    /// actor hop between the caller's own `isCurrent` check and this call,
    /// so `abort()` cannot interleave before the write, but that is an
    /// accident of the current call shape, not a guarantee. If a stale
    /// pipeline ever reached this write unguarded, it would set `.polishing`
    /// after `abort()` had already returned the coordinator to `.idle`,
    /// leaving it permanently busy with no work left to move it out again.
    private func cleanIfEnabled(_ text: String, token: Int) async -> String {
        guard preferences.cleanupEnabled, let cleaner else { return text }
        guard isCurrent(token) else { return text }
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
    /// `begin()` treats it as non-busy, so the next press starts cleanly.
    /// A cancellable timer returns it to `.idle` after the same delay the
    /// presenter uses to dismiss its display, so an unattended failure does
    /// not sit in the menu bar forever.
    private func fail(_ message: String) {
        state = .failed(message)
        presenter.dismiss(after: config.noticeDismissDelay)
        scheduleTerminalReset()
    }

    /// See `fail(_:)`: leaves `state` at `.notice` and schedules the same
    /// cancellable return to `.idle`.
    private func notice(_ message: String) {
        state = .notice(message)
        presenter.dismiss(after: config.noticeDismissDelay)
        scheduleTerminalReset()
    }

    /// Returns `state` to `.idle` after `config.noticeDismissDelay`, but
    /// only if it is still the same resting value this call captured — a
    /// fresh press (which cancels this task) or another terminal state
    /// arriving first must not be clobbered.
    private func scheduleTerminalReset() {
        terminalResetTask?.cancel()
        let restingState = state
        let delay = config.noticeDismissDelay
        terminalResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.state == restingState {
                self.state = .idle
            }
        }
    }
}
