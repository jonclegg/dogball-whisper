import Foundation
import Observation

enum ModelManagerError: LocalizedError, Equatable {
    case deletingWhileInstalling

    var errorDescription: String? {
        switch self {
        case .deletingWhileInstalling:
            return "This model is currently downloading. Wait for it to finish before deleting it."
        }
    }
}

/// Owns model installation and which engine is live. One download at a time,
/// because two 500MB transfers at once help nobody.
///
/// `engineFactory` and `isInstalled` are injectable (defaulting to the real
/// engines and `ModelCatalog.isInstalled`) so tests can drive install,
/// delete, and activation without a network or real model files.
@MainActor
@Observable
final class ModelManager {
    typealias EngineFactory = (ModelDescriptor, @escaping @Sendable (Double) -> Void) -> TranscriptionEngine
    typealias InstallCheck = (ModelDescriptor) -> Bool

    /// Download fraction per model ID, present only while downloading.
    private(set) var progress: [String: Double] = [:]
    private(set) var activeEngine: TranscriptionEngine?
    private(set) var lastError: String?

    private let preferences: Preferences
    private let engineFactory: EngineFactory
    private let isInstalled: InstallCheck
    private var installTask: Task<Void, Error>?

    init(
        preferences: Preferences,
        engineFactory: @escaping EngineFactory = ModelManager.defaultEngineFactory,
        isInstalled: @escaping InstallCheck = ModelCatalog.isInstalled
    ) {
        self.preferences = preferences
        self.engineFactory = engineFactory
        self.isInstalled = isInstalled
    }

    var activeModelID: String? {
        preferences.activeModelID
    }

    var isBusy: Bool { installTask != nil }

    func state(for descriptor: ModelDescriptor) -> ModelInstallState {
        ModelCatalog.state(
            for: descriptor, activeID: preferences.activeModelID, progress: progress,
            isInstalled: isInstalled)
    }

    func install(_ descriptor: ModelDescriptor) async throws {
        guard installTask == nil else { return }
        progress[descriptor.id] = 0

        // Loading an engine is what downloads it, so install is "load, then
        // throw the engine away" unless it becomes the active model below.
        let engine = engineFactory(descriptor) { [weak self] fraction in
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
        // Deleting files out from under a running download would corrupt the
        // in-progress transfer; refuse rather than race it. The install task
        // itself would recover (it throws and clears its own handle), but a
        // deliberate refusal makes the invariant explicit instead of relying
        // on self-healing.
        guard progress[descriptor.id] == nil else {
            throw ModelManagerError.deletingWhileInstalling
        }

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

    /// Switches the active model. Unloads the current engine before loading
    /// the new one — only one model's weights are ever resident at once.
    ///
    /// The persisted `activeModelID` is only written once the new engine has
    /// actually finished loading. If the load throws, the previous engine is
    /// already gone, so this rolls back to the previous selection and — if
    /// its files are still installed — reloads it, rather than leaving
    /// `activeModelID` pointing at a model with no live engine. If even that
    /// reload fails, the selection is cleared to nil rather than left
    /// dangling: the invariant is that `activeModelID` names a model whose
    /// engine is actually loaded, or nothing.
    func makeActive(_ descriptor: ModelDescriptor) async throws {
        let previousID = preferences.activeModelID
        activeEngine?.unload()
        activeEngine = nil

        do {
            let engine = engineFactory(descriptor) { _ in }
            try await engine.load()
            activeEngine = engine
            preferences.activeModelID = descriptor.id
        } catch {
            lastError = error.localizedDescription
            preferences.activeModelID = previousID
            if let previousID,
               let previousDescriptor = ModelCatalog.descriptor(id: previousID),
               isInstalled(previousDescriptor)
            {
                do {
                    let restored = engineFactory(previousDescriptor) { _ in }
                    try await restored.load()
                    activeEngine = restored
                } catch {
                    preferences.activeModelID = nil
                }
            } else {
                preferences.activeModelID = nil
            }
            throw error
        }
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
              isInstalled(descriptor)
        else {
            activeEngine = nil
            return
        }
        let engine = engineFactory(descriptor) { _ in }
        try await engine.load()
        activeEngine = engine
    }

    // Touches no MainActor-isolated state (no `self`, no `progress`/`activeEngine`),
    // so it is explicitly nonisolated. Without this, referencing it as an
    // `init` default value implicitly inherits @MainActor from the enclosing
    // class and the compiler cannot preserve that isolation across the
    // conversion to the plain (non-actor) `EngineFactory` type, which is a
    // warning today and an error under the Swift 6 language mode.
    private nonisolated static func defaultEngineFactory(
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
