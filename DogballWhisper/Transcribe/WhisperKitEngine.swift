import Foundation
import WhisperKit

/// A Whisper model via WhisperKit. Once the files are on disk we never let
/// WhisperKit re-sync against HuggingFace: that rewrites files and forces a
/// slow CoreML recompile on the next load.
final class WhisperKitEngine: TranscriptionEngine {
    let kind: EngineKind = .whisper
    private(set) var isLoaded = false

    private let variant: String
    private let onDownloadProgress: @Sendable (Double) -> Void
    private var pipeline: WhisperKit?
    private let loadOnce = LoadOnce<Void>()

    init(variant: String, onDownloadProgress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.variant = variant
        self.onDownloadProgress = onDownloadProgress
    }

    /// Downloads the model (if needed) and loads it. Wrapped in `LoadOnce` for
    /// the same reason as `ParakeetEngine`: concurrent callers (dictation and
    /// the settings model manager) coalesce onto one run instead of racing
    /// two downloads onto the same partial file.
    func load() async throws {
        if isLoaded { return }
        let variant = variant
        let onDownloadProgress = onDownloadProgress
        try await loadOnce.run { [weak self] in
            let descriptor = ModelCatalog.all.first {
                if case let .whisperKit(v) = $0.source { return v == variant }
                return false
            }
            var folder = descriptor.map(ModelCatalog.installedLocation(for:))
                ?? ModelCatalog.whisperDownloadBase

            if descriptor.map(ModelCatalog.isInstalled) != true {
                folder = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: ModelCatalog.whisperDownloadBase,
                    progressCallback: { progress in
                        onDownloadProgress(progress.fractionCompleted)
                    }
                )
            }

            let config = WhisperKitConfig(
                model: variant,
                modelFolder: folder.path,
                load: true,
                download: false
            )
            let pipeline = try await WhisperKit(config)
            guard let self else { return }
            self.pipeline = pipeline
            self.isLoaded = true
        }
    }

    func unload() {
        pipeline = nil
        isLoaded = false
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        guard let pipeline else { throw TranscriptionError.notLoaded }
        let results = try await pipeline.transcribe(audioPath: audioURL.path)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
