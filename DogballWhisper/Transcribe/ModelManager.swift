import Foundation
import Observation

enum ModelManagerError: LocalizedError, Equatable {
    case deletingWhileInstalling
    case installInProgress
    case activationInProgress

    var errorDescription: String? {
        switch self {
        case .deletingWhileInstalling:
            return "This model is currently downloading. Wait for it to finish before deleting it."
        case .installInProgress:
            return "Another model is downloading. Wait for it to finish before starting another one."
        case .activationInProgress:
            return "Another model is loading. Wait for it to finish before switching models."
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

    /// The model being switched to, present only while `makeActive` is
    /// loading it, so the UI can show a spinner on that row.
    private(set) var activatingModelID: String?

    private let preferences: Preferences
    private let engineFactory: EngineFactory
    private let isInstalled: InstallCheck
    private var installTask: Task<Void, Error>?
    private var activationTask: Task<Void, Error>?

    /// The model whose weights `activeEngine` holds, kept in lockstep with it
    /// so `loadActiveEngine()` can tell a redundant reload from a real one.
    /// Not the same thing as `activeModelID`, which is the persisted
    /// selection and is only written once a load has succeeded.
    private var loadedEngineID: String?

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

    /// True while a download or an activation is in flight. Both hold the
    /// model list still: a second install, a second activation, or a delete
    /// underneath either one would race the work already running.
    var isBusy: Bool { installTask != nil || activationTask != nil }

    func state(for descriptor: ModelDescriptor) -> ModelInstallState {
        ModelCatalog.state(
            for: descriptor, activeID: preferences.activeModelID, progress: progress,
            isInstalled: isInstalled)
    }

    /// Downloads a model, then makes it active if nothing else is.
    ///
    /// Throws `.installInProgress`/`.activationInProgress` rather than
    /// returning quietly when the manager is busy: returning normally would be
    /// indistinguishable from success to a caller, which is how a refused
    /// install could look like a finished one.
    func install(_ descriptor: ModelDescriptor) async throws {
        guard installTask == nil else { throw ModelManagerError.installInProgress }
        guard activationTask == nil else { throw ModelManagerError.activationInProgress }
        lastError = nil
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
        // Same argument for activation: removing files under an engine that is
        // mid-load, or under a rollback about to reload the previous model,
        // corrupts work already in flight.
        guard activationTask == nil else {
            throw ModelManagerError.activationInProgress
        }

        if preferences.activeModelID == descriptor.id {
            unloadActiveEngine()
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

    /// Switches the active model, one at a time.
    ///
    /// Serialized the way `install` is: a large model takes seconds to load,
    /// and two overlapping calls would both unload, both build an engine, and
    /// both write `activeEngine`/`activeModelID` — so one call's rollback
    /// could clear a selection the other had just committed. A second call
    /// while one is in flight throws instead of running a racing body.
    func makeActive(_ descriptor: ModelDescriptor) async throws {
        guard activationTask == nil else { throw ModelManagerError.activationInProgress }
        lastError = nil
        let task = Task { try await self.activate(descriptor) }
        activationTask = task
        activatingModelID = descriptor.id
        defer {
            activationTask = nil
            activatingModelID = nil
        }
        try await task.value
    }

    /// Unloads the current engine before loading
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
    private func activate(_ descriptor: ModelDescriptor) async throws {
        let previousID = preferences.activeModelID
        unloadActiveEngine()

        do {
            let engine = engineFactory(descriptor) { _ in }
            try await engine.load()
            setActiveEngine(engine, id: descriptor.id)
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
                    setActiveEngine(restored, id: previousID)
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
        lastError = nil
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
            unloadActiveEngine()
            return
        }
        // Onboarding's install already activated this exact model, so at the
        // end of a first run its engine is loaded and reloading it would pay a
        // second cold start for nothing.
        if let engine = activeEngine, loadedEngineID == id, engine.isLoaded { return }
        // Unload first: loading a second engine while the outgoing one is
        // still resident would hold two full models' weights at once.
        unloadActiveEngine()
        let engine = engineFactory(descriptor) { _ in }
        try await engine.load()
        setActiveEngine(engine, id: descriptor.id)
    }

    private func setActiveEngine(_ engine: TranscriptionEngine?, id: String?) {
        activeEngine = engine
        loadedEngineID = id
    }

    private func unloadActiveEngine() {
        activeEngine?.unload()
        setActiveEngine(nil, id: nil)
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
