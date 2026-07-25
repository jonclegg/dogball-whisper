import FluidAudio
import Foundation

/// Parakeet TDT 0.6b v3 via FluidAudio. Model files come from our own
/// CloudFront mirror (see ModelMirror) so FluidAudio never touches HuggingFace
/// and we get byte-accurate download progress.
final class ParakeetEngine: TranscriptionEngine {
    let kind: EngineKind = .parakeet
    private(set) var isLoaded = false

    private var manager: AsrManager?
    private let onDownloadProgress: (Double) -> Void

    init(onDownloadProgress: @escaping (Double) -> Void = { _ in }) {
        self.onDownloadProgress = onDownloadProgress
    }

    func load() async throws {
        guard !isLoaded else { return }
        if !ModelMirror.isComplete() {
            try await ModelMirror.download(onProgress: onDownloadProgress)
        }
        let models = try await AsrModels.downloadAndLoad()
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
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
