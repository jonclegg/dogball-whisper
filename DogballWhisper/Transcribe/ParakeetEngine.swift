import FluidAudio
import Foundation

/// Parakeet TDT 0.6b v3 via FluidAudio. Model files come from our own
/// CloudFront mirror (see ModelMirror) so FluidAudio never touches HuggingFace
/// and we get byte-accurate download progress.
final class ParakeetEngine: TranscriptionEngine {
    let kind: EngineKind = .parakeet
    private(set) var isLoaded = false

    private var manager: AsrManager?
    private let onDownloadProgress: @Sendable (Double) -> Void
    private let loadOnce = LoadOnce<AsrManager>()

    init(onDownloadProgress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.onDownloadProgress = onDownloadProgress
    }

    /// Downloads the model (if needed) and loads it. Safe to call
    /// concurrently — e.g. once from the dictation coordinator and once from
    /// the settings model manager — because `LoadOnce` makes every caller
    /// await the same in-flight run instead of racing two downloads onto the
    /// same on-disk partial file. `manager` and `isLoaded` are only set
    /// together, and only after the run succeeds; a thrown error leaves both
    /// untouched so a later call retries.
    func load() async throws {
        let onDownloadProgress = onDownloadProgress
        let manager = try await loadOnce.run {
            if !ModelMirror.isComplete() {
                try await ModelMirror.download(onProgress: onDownloadProgress)
            }
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        self.manager = manager
        isLoaded = true
    }

    func unload() {
        manager = nil
        isLoaded = false
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        guard let manager else { throw TranscriptionError.notLoaded }
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
