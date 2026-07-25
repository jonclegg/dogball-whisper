import Foundation
import Observation

/// Owns model installation and which engine is live. One download at a time,
/// because two 500MB transfers at once help nobody.
@MainActor
@Observable
final class ModelManager {
    /// Download fraction per model ID, present only while downloading.
    private(set) var progress: [String: Double] = [:]
    private(set) var activeEngine: TranscriptionEngine?
    private(set) var lastError: String?

    private let preferences: Preferences
    private var installTask: Task<Void, Error>?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var activeModelID: String? {
        preferences.activeModelID
    }

    var isBusy: Bool { installTask != nil }

    func state(for descriptor: ModelDescriptor) -> ModelInstallState {
        ModelCatalog.state(
            for: descriptor, activeID: preferences.activeModelID, progress: progress)
    }

    func install(_ descriptor: ModelDescriptor) async throws {
        guard installTask == nil else { return }
        progress[descriptor.id] = 0

        // Loading an engine is what downloads it, so install is "load, then
        // throw the engine away" unless it becomes the active model below.
        let engine = makeEngine(for: descriptor) { [weak self] fraction in
            Task { @MainActor in self?.progress[descriptor.id] = fraction }
        }
        let task = Task {
            try await engine.load()
            engine.unload()
        }
        installTask = task

        // Cleared here rather than in the task's defer: the task starts running
        // immediately, so a defer could clear installTask before it was set and
        // leave a stale value that blocks every later install.
        defer {
            progress[descriptor.id] = nil
            installTask = nil
        }
        do {
            try await task.value
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        // First model installed becomes the active one.
        if preferences.activeModelID == nil {
            try await makeActive(descriptor)
        }
    }

    func delete(_ descriptor: ModelDescriptor) throws {
        if preferences.activeModelID == descriptor.id {
            activeEngine?.unload()
            activeEngine = nil
            preferences.activeModelID = nil
        }
        switch descriptor.source {
        case .parakeetMirror:
            try ModelMirror.deleteModel()
        case .whisperKit:
            let folder = ModelCatalog.installedLocation(for: descriptor)
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        }
    }

    func makeActive(_ descriptor: ModelDescriptor) async throws {
        activeEngine?.unload()
        activeEngine = nil
        preferences.activeModelID = descriptor.id
        try await loadActiveEngineThrowing()
    }

    /// Called at launch so the first dictation does not pay a cold start.
    func loadActiveEngine() async {
        do {
            try await loadActiveEngineThrowing()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadActiveEngineThrowing() async throws {
        guard let id = preferences.activeModelID,
              let descriptor = ModelCatalog.descriptor(id: id),
              ModelCatalog.isInstalled(descriptor)
        else {
            activeEngine = nil
            return
        }
        let engine = makeEngine(for: descriptor) { _ in }
        try await engine.load()
        activeEngine = engine
    }

    private func makeEngine(
        for descriptor: ModelDescriptor, onProgress: @escaping @Sendable (Double) -> Void
    ) -> TranscriptionEngine {
        switch descriptor.source {
        case .parakeetMirror:
            return ParakeetEngine(onDownloadProgress: onProgress)
        case let .whisperKit(variant):
            return WhisperKitEngine(variant: variant, onDownloadProgress: onProgress)
        }
    }
}
