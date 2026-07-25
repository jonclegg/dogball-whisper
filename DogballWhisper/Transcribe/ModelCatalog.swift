import Foundation

struct ModelDescriptor: Identifiable, Equatable {
    enum Source: Equatable {
        case parakeetMirror
        /// A directory name in argmaxinc/whisperkit-coreml.
        case whisperKit(variant: String)
    }

    let id: String
    let name: String
    let detail: String
    let engineKind: EngineKind
    let sizeBytes: Int64
    let source: Source

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum ModelInstallState: Equatable {
    case notInstalled
    case downloading(Double)
    case installed
    case active
}

enum ModelCatalog {
    static let defaultModelID = "parakeet-v3"

    static let all: [ModelDescriptor] = [
        ModelDescriptor(
            id: defaultModelID,
            name: "Parakeet V3",
            detail: "Fastest, 25 European languages",
            engineKind: .parakeet,
            sizeBytes: 483_000_000,
            source: .parakeetMirror
        ),
        ModelDescriptor(
            id: "whisper-tiny-en",
            name: "Whisper Tiny (English)",
            detail: "Smallest, least accurate",
            engineKind: .whisper,
            sizeBytes: 75_000_000,
            source: .whisperKit(variant: "openai_whisper-tiny.en")
        ),
        ModelDescriptor(
            id: "whisper-base-en",
            name: "Whisper Base (English)",
            detail: "Small and quick",
            engineKind: .whisper,
            sizeBytes: 145_000_000,
            source: .whisperKit(variant: "openai_whisper-base.en")
        ),
        ModelDescriptor(
            id: "whisper-small-en",
            name: "Whisper Small (English)",
            detail: "Good accuracy",
            engineKind: .whisper,
            sizeBytes: 483_000_000,
            source: .whisperKit(variant: "openai_whisper-small.en")
        ),
        ModelDescriptor(
            id: "whisper-large-v3-turbo",
            name: "Whisper Large V3 Turbo",
            detail: "Most accurate, 99 languages",
            engineKind: .whisper,
            sizeBytes: 632_000_000,
            source: .whisperKit(variant: "openai_whisper-large-v3-v20240930_turbo_632MB")
        ),
    ]

    static func descriptor(id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }

    /// Our own download root. WhisperKit defaults to ~/Documents, which is the
    /// wrong place for a background menu-bar app's model files.
    static var whisperDownloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogballWhisper/Models", isDirectory: true)
    }

    static func installedLocation(for descriptor: ModelDescriptor) -> URL {
        switch descriptor.source {
        case .parakeetMirror:
            let prefix = (try? ModelMirror.loadManifest().prefix) ?? "parakeet-tdt-0.6b-v3"
            return ModelMirror.modelsDirectory(prefix: prefix)
        case let .whisperKit(variant):
            return whisperDownloadBase
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(variant, isDirectory: true)
        }
    }

    static func isInstalled(_ descriptor: ModelDescriptor) -> Bool {
        switch descriptor.source {
        case .parakeetMirror:
            return ModelMirror.isComplete()
        case .whisperKit:
            let folder = installedLocation(for: descriptor)
            let required = [
                "config.json",
                "AudioEncoder.mlmodelc/weights/weight.bin",
                "TextDecoder.mlmodelc/weights/weight.bin",
                "MelSpectrogram.mlmodelc/weights/weight.bin",
            ]
            return required.allSatisfy {
                FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent($0).path)
            }
        }
    }

    /// `isInstalled` is injectable (defaulting to the real on-disk check) so
    /// callers — notably tests — can drive every branch deterministically
    /// instead of depending on what happens to be downloaded on the machine
    /// running the suite.
    static func state(
        for descriptor: ModelDescriptor, activeID: String?, progress: [String: Double],
        isInstalled isInstalledCheck: (ModelDescriptor) -> Bool = isInstalled
    ) -> ModelInstallState {
        if let fraction = progress[descriptor.id] { return .downloading(fraction) }
        guard isInstalledCheck(descriptor) else { return .notInstalled }
        return descriptor.id == activeID ? .active : .installed
    }
}
