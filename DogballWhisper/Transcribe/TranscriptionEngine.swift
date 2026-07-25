import Foundation

enum EngineKind: String, Codable {
    case parakeet
    case whisper
}

enum TranscriptionError: LocalizedError, Equatable {
    case notLoaded
    case noModelInstalled

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "The transcription model is still loading."
        case .noModelInstalled:
            return "No model installed. Open Settings and download one."
        }
    }
}

/// One loaded speech model. Implementations keep the model resident so no
/// dictation pays a cold-start cost.
protocol TranscriptionEngine: AnyObject {
    var kind: EngineKind { get }
    var isLoaded: Bool { get }
    func load() async throws
    func unload()
    func transcribe(_ audioURL: URL) async throws -> String
}
