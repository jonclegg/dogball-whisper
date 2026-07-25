import AVFoundation

struct RecordedAudio: Equatable {
    let url: URL
    let duration: TimeInterval
}

enum AudioRecorderError: LocalizedError, Equatable {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return "Could not start recording. Check that no other app is using the microphone."
        }
    }
}

protocol AudioRecording: AnyObject {
    var levels: [Float] { get }
    func start() throws
    func stop() -> RecordedAudio?
    func cancel()
}

/// Records 16kHz mono PCM straight to a WAV file, which is exactly what both
/// transcription engines want. There is no AVAudioSession on macOS, so there is
/// nothing to configure or tear down around each recording.
///
/// `start()` is on the hot path: it runs the instant the hotkey is pressed, so
/// device open and hardware readying must not sit inside the user's first
/// syllable. `AVAudioRecorder.prepareToRecord()` is the seam that lets that
/// work happen ahead of time — it opens the device and creates the output
/// file without capturing anything, so a later `record()` call starts almost
/// immediately. `prewarm()` does that ahead-of-time preparation; `start()`
/// consumes whatever it produced, or falls back to preparing inline exactly
/// as before if nothing was ready in time.
///
/// All of this class's methods, `prewarm()` included, are main-thread-only,
/// matching the meter timer's existing assumption (it runs on `RunLoop.main`).
/// `prewarm()` stays cheap on that thread by doing only the state check
/// there; the actual hardware work happens on `prewarmQueue` and the result
/// is handed back via `DispatchQueue.main.async`.
final class AudioRecorder: AudioRecording {
    static let levelWindowSize = 40
    static let meterWarmUp: TimeInterval = 0.3

    private static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    private(set) var levels: [Float] = Array(repeating: 0, count: AudioRecorder.levelWindowSize)

    private let onLevels: ([Float]) -> Void
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    /// A recorder that has already run `prepareToRecord()` for the next
    /// dictation, and the file it was prepared against. `start()` consumes
    /// these when present instead of building and preparing from scratch.
    private var prewarmed: AVAudioRecorder?
    private var prewarmedURL: URL?
    private var isPrewarming = false

    private let prewarmQueue = DispatchQueue(
        label: "com.jonclegg.DogballWhisper.AudioRecorder.prewarm", qos: .utility)
    private var deviceChangeObservers: [NSObjectProtocol] = []

    init(onLevels: @escaping ([Float]) -> Void = { _ in }) {
        self.onLevels = onLevels
        observeDeviceChanges()
    }

    deinit {
        timer?.invalidate()
        deviceChangeObservers.forEach(NotificationCenter.default.removeObserver)
        if let prewarmedURL {
            try? FileManager.default.removeItem(at: prewarmedURL)
        }
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Maps a metered dBFS reading (-160...0) to a 0...1 bar height, treating
    /// anything inside the warm-up window as silence.
    static func normalizedLevel(fromDb db: Float, at time: TimeInterval) -> Float {
        guard time >= meterWarmUp else { return 0 }
        return max(0, min(1, (db + 50) / 50))
    }

    static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogballWhisper/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Pure decision for whether pre-warming should touch hardware at all:
    /// only when the mic is already authorized (pre-warming must never
    /// itself trigger the permission prompt), nothing is currently
    /// recording, and nothing is armed already (idempotent — a second call
    /// while one is already prepared is a no-op). Kept free of any
    /// AVAudioRecorder/AVCaptureDevice call so it is unit-testable without
    /// touching real hardware.
    static func shouldPrewarm(authorized: Bool, isRecording: Bool, isArmed: Bool) -> Bool {
        authorized && !isRecording && !isArmed
    }

    func start() throws {
        // A second start would otherwise leak the running timer and abandon the
        // first recording's file, which nothing would ever delete.
        if recorder != nil { cancel() }

        let recorderToUse: AVAudioRecorder
        let url: URL

        if let prewarmed, let prewarmedURL {
            // The common case once the app has been running for a moment:
            // device open and file creation already happened in prewarm().
            recorderToUse = prewarmed
            url = prewarmedURL
            self.prewarmed = nil
            self.prewarmedURL = nil
        } else {
            // No prepared recorder yet (first dictation right after launch,
            // before the launch-time prewarm finished, or mic access was
            // only just granted). Behaves exactly as before pre-warming
            // existed.
            url = Self.recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            recorderToUse = try AVAudioRecorder(url: url, settings: Self.pcmSettings)
            recorderToUse.isMeteringEnabled = true
        }

        // A discarded `record()` result turns a refused start into a silent
        // zero-length recording, which the sub-300ms rule then throws away
        // with no message at all. Fail loudly instead.
        guard recorderToUse.record() else {
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.couldNotStart
        }

        self.recorder = recorderToUse
        self.fileURL = url
        self.levels = Array(repeating: 0, count: Self.levelWindowSize)

        timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.sampleMeter()
        }
        // .common keeps the meter firing while a menu is tracking or a modal run
        // loop is active, instead of freezing whenever the app's UI is doing that.
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() -> RecordedAudio? {
        timer?.invalidate()
        timer = nil
        guard let recorder, let fileURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil
        // Re-arm immediately so the next dictation is fast too, not just the
        // first one.
        prewarm()
        return RecordedAudio(url: fileURL, duration: duration)
    }

    func cancel() {
        if let result = stop() {
            try? FileManager.default.removeItem(at: result.url)
        }
    }

    /// Readies the next `AVAudioRecorder` ahead of time so the next `start()`
    /// only has to call `record()`. Safe to call at launch, after every
    /// `stop()`/`cancel()`, and speculatively (e.g. on a device change) —
    /// it no-ops unless `shouldPrewarm` says to proceed, and the hardware
    /// work itself runs off the main thread so callers are never blocked.
    ///
    /// This never engages the microphone: `prepareToRecord()` opens the
    /// device and negotiates formats but does not start capture, so it does
    /// not light the orange recording indicator.
    func prewarm() {
        guard !isPrewarming else { return }
        let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard Self.shouldPrewarm(
            authorized: authorized, isRecording: recorder != nil, isArmed: prewarmed != nil
        ) else { return }

        isPrewarming = true
        let url = Self.recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let settings = Self.pcmSettings

        prewarmQueue.async { [weak self] in
            let candidate = try? AVAudioRecorder(url: url, settings: settings)
            candidate?.isMeteringEnabled = true
            candidate?.prepareToRecord()

            DispatchQueue.main.async {
                guard let self else {
                    // The recorder was torn down while this was in flight;
                    // nothing left to hand the result to.
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.isPrewarming = false
                // Re-check on the way back in: a real recording may have
                // started, or another prewarm may have already landed,
                // while this one was on the background queue. Either way
                // this result is now stale and must not clobber state or
                // leak its zero-byte file.
                guard let candidate, self.recorder == nil, self.prewarmed == nil else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.prewarmed = candidate
                self.prewarmedURL = url
            }
        }
    }

    /// Drops whatever is currently armed, deleting its zero-byte file. Used
    /// when a prepared recorder might no longer be valid (the default input
    /// device changed) rather than letting `start()` discover that the hard
    /// way.
    private func discardPrewarmed() {
        guard let prewarmedURL else { return }
        prewarmed = nil
        self.prewarmedURL = nil
        try? FileManager.default.removeItem(at: prewarmedURL)
    }

    /// `AVAudioRecorder` has no API to move a prepared instance onto a new
    /// input device, and there is no documented guarantee that one prepared
    /// against the previous default device keeps working after the default
    /// changes (headset unplugged, etc.). Rebuilding is cheap and safe, so
    /// rather than risk recording silence or failing at `record()` time,
    /// throw away whatever was armed and prepare again from scratch.
    private func rearmForDeviceChange() {
        discardPrewarmed()
        prewarm()
    }

    private func observeDeviceChanges() {
        let center = NotificationCenter.default
        let handleDeviceChange: (Notification) -> Void = { [weak self] note in
            // These notifications fire for any AVCaptureDevice (cameras
            // included); only an audio device change is relevant here.
            guard let device = note.object as? AVCaptureDevice, device.hasMediaType(.audio) else {
                return
            }
            self?.rearmForDeviceChange()
        }
        deviceChangeObservers = [
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main,
                using: handleDeviceChange),
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main,
                using: handleDeviceChange),
        ]
    }

    private func sampleMeter() {
        guard let recorder else { return }
        recorder.updateMeters()
        let level = Self.normalizedLevel(
            fromDb: recorder.averagePower(forChannel: 0), at: recorder.currentTime)
        levels.append(level)
        if levels.count > Self.levelWindowSize { levels.removeFirst() }
        onLevels(levels)
    }
}
