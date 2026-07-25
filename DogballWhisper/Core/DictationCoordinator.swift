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

/// Where the caret is, and whether dictating there is allowed at all.
/// Injected so the refusal path — the one place a bug means shipping a
/// password to a third party — is testable without a real focused app, and
/// so tests never set accessibility attributes on whatever happens to be
/// frontmost while they run.
typealias CaretProvider = () -> CaretLocation
/// The cheap, in-process half of the same question (`IsSecureEventInputEnabled`).
typealias SecureInputProvider = () -> Bool

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
    private let caretProvider: CaretProvider
    private let secureInputProvider: SecureInputProvider
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
        caretProvider: @escaping CaretProvider = CaretLocator.current,
        secureInputProvider: @escaping SecureInputProvider = CaretLocator.isSecureInputActive,
        config: Config = Config()
    ) {
        self.recorder = recorder
        self.engineProvider = engineProvider
        self.inserter = inserter
        self.cleaner = cleaner
        self.presenter = presenter
        self.preferences = preferences
        self.caretProvider = caretProvider
        self.secureInputProvider = secureInputProvider
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

        // The previous dictation's caret is not this one's: anything
        // presented from here on (including a refusal or a failure) belongs
        // at the fallback position rather than wherever the last one landed.
        location = .unknown

        // Dictated text is sent to OpenRouter for cleanup, so recording into
        // a password field would ship the password to a third party. The
        // cheap half of that gate — secure event input, which covers a sudo
        // or ssh prompt in a terminal and every macOS auth dialog — runs
        // first, before anything else is true or false: it is in-process,
        // costs nothing, and needs no accessibility permission.
        guard !secureInputProvider() else {
            refuseSecureField(reason: "secure event input")
            return
        }
        guard engineProvider() != nil else {
            fail(TranscriptionError.noModelInstalled.localizedDescription)
            return
        }

        // Nothing above this line touches the accessibility API, and nothing
        // between here and `recorder.start()` may either. Locating the caret
        // is cross-process IPC into whatever app is frontmost, which is
        // exactly the kind of work `AudioRecorder`'s pre-warming exists to
        // keep out of the user's first syllable. The panel is presented by
        // the `state = .recording` write below, so `location` only has to be
        // known by then, not before the microphone is capturing.
        do {
            try recorder.start()
        } catch {
            fail(error.localizedDescription)
            return
        }

        location = caretProvider()
        // The accessibility half of the gate: a password field that secure
        // event input did not cover (a web `input[type=password]`, say).
        // Later than the check above, so the recording that already started
        // has to be thrown away — `cancel()` stops the recorder and deletes
        // its file, and nothing was transcribed, cleaned, or inserted.
        guard !location.isSecureField else {
            recorder.cancel()
            location = .unknown
            refuseSecureField(reason: "secure text field")
            return
        }
        state = .recording
    }

    /// Both refusals show the same thing; the reason is logged rather than
    /// displayed, because it is the only way to tell a genuine password
    /// prompt from an app that left secure event input engaged behind it
    /// (Terminal's "Secure Keyboard Entry" being the usual suspect) when a
    /// user reports dictation refusing everywhere.
    ///
    /// Verbose, not a plain log, even though it is a refusal: at `notice`
    /// with `.public` this persists for days, and a durable record of the
    /// moments a user was sitting at a password prompt is worth more to an
    /// attacker than it is to us. Someone chasing a stuck refusal turns the
    /// flag on and reproduces it.
    private func refuseSecureField(reason: String) {
        Diagnostics.verbose("dictation refused: \(reason)")
        notice("Not in a password field")
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
        Diagnostics.verbose(
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
        guard preferences.cleanupEnabled else {
            Diagnostics.verbose("cleanup skipped: disabled in settings")
            return text
        }
        guard let cleaner else {
            Diagnostics.verbose("cleanup skipped: no cleaner wired up")
            return text
        }
        guard isCurrent(token) else {
            Diagnostics.verbose("cleanup skipped: pipeline superseded")
            return text
        }
        state = .polishing
        let prompt = preferences.cleanupPrompt
        let model = preferences.cleanupModelID
        Diagnostics.verbose(
            "cleanup starting: model=\(model) promptChars=\(prompt.count) textChars=\(text.count) timeout=\(config.cleanupTimeout)s")
        let started = Date()
        do {
            let cleaned = try await withTimeout(seconds: config.cleanupTimeout) {
                try await cleaner.clean(text, prompt: prompt, model: model)
            }
            let elapsed = Date().timeIntervalSince(started)
            Diagnostics.verbose(
                "cleanup ok in \(Int(elapsed * 1000))ms: \(text.count) -> \(cleaned.count) chars")
            return cleaned
        } catch is TimedOutError {
            // The most likely cause of "cleanup stopped working": the request
            // is fine but slower than the budget, so every dictation silently
            // falls back to the raw transcript.
            Diagnostics.log(
                "cleanup TIMED OUT after \(config.cleanupTimeout)s, inserting the raw transcript")
            return text
        } catch let error as PolishError where error == .missingAPIKey {
            // Not a failure: cleanup is optional, and having no key is an
            // ordinary way to run this app. Logging it at notice level would
            // persist a timestamped line for every dictation the user makes.
            Diagnostics.verbose("cleanup skipped: no API key")
            return text
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            // The error's shape and status, never its description.
            // `PolishError.http` carries up to 300 bytes of the provider's
            // response body, and providers echo the submitted text back in
            // moderation rejections — so `localizedDescription` here would be
            // a route from a transcript into the system log.
            Diagnostics.log(
                "cleanup FAILED after \(Int(elapsed * 1000))ms: \(Diagnostics.describe(error))")
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
