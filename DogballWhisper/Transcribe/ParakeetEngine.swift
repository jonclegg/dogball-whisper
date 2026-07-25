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
    private let loadOnce = LoadOnce<Void>()

    init(onDownloadProgress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.onDownloadProgress = onDownloadProgress
    }

    /// Downloads the model (if needed) and loads it. `isLoaded` makes repeat
    /// calls free once loading has succeeded. Concurrent callers before that
    /// — e.g. once from the dictation coordinator and once from the settings
    /// model manager — all await the same `LoadOnce`-coalesced run instead of
    /// racing two downloads onto the same on-disk partial file. `manager` and
    /// `isLoaded` are written inside that single run, so exactly one
    /// execution ever touches them and a thrown error leaves both untouched
    /// for a clean retry.
    func load() async throws {
        if isLoaded { return }
        let onDownloadProgress = onDownloadProgress
        try await loadOnce.run { [weak self] in
            if !ModelMirror.isComplete() {
                try await ModelMirror.download(onProgress: onDownloadProgress)
            }
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            guard let self else { return }
            self.manager = manager
            self.isLoaded = true
        }
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
