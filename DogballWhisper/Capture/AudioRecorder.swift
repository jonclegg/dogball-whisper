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
final class AudioRecorder: AudioRecording {
    static let levelWindowSize = 40
    static let meterWarmUp: TimeInterval = 0.3

    private(set) var levels: [Float] = Array(repeating: 0, count: AudioRecorder.levelWindowSize)

    private let onLevels: ([Float]) -> Void
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    init(onLevels: @escaping ([Float]) -> Void = { _ in }) {
        self.onLevels = onLevels
    }

    deinit { timer?.invalidate() }

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

    func start() throws {
        // A second start would otherwise leak the running timer and abandon the
        // first recording's file, which nothing would ever delete.
        if recorder != nil { cancel() }

        let url = Self.recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        // A discarded `record()` result turns a refused start into a silent
        // zero-length recording, which the sub-300ms rule then throws away
        // with no message at all. Fail loudly instead.
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.couldNotStart
        }

        self.recorder = recorder
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
        return RecordedAudio(url: fileURL, duration: duration)
    }

    func cancel() {
        if let result = stop() {
            try? FileManager.default.removeItem(at: result.url)
        }
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
