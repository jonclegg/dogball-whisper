import XCTest
@testable import DogballWhisper

// MARK: - Fakes

/// Lets a test hold `FakeModelEngine.load()` open until it is ready to let it
/// proceed, so concurrency-dependent behavior (the one-download-at-a-time
/// guard) can be proven without racing against a fixed sleep.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Shared, ordered record of load/unload events across every `FakeModelEngine`,
/// so tests can prove sequencing (e.g. "unloaded before the next loaded")
/// rather than just that both happened.
private final class EventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private struct FakeLoadError: Error, Equatable {}

private final class FakeModelEngine: TranscriptionEngine {
    let kind: EngineKind
    let id: String
    private(set) var isLoaded = false
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    var loadError: Error?
    var gate: Gate?
    private let log: EventLog

    init(id: String, kind: EngineKind, log: EventLog) {
        self.id = id
        self.kind = kind
        self.log = log
    }

    func load() async throws {
        loadCount += 1
        if let gate { await gate.wait() }
        if let loadError {
            log.record("load-failed:\(id)")
            throw loadError
        }
        isLoaded = true
        log.record("loaded:\(id)")
    }

    func unload() {
        unloadCount += 1
        isLoaded = false
        log.record("unloaded:\(id)")
    }

    func transcribe(_ audioURL: URL) async throws -> String { "" }
}

/// Records every engine `ModelManager` asks for, keyed by descriptor id, so
/// tests can configure a failure or a block per model id and inspect exactly
/// what got loaded/unloaded afterward — without a network or real model
/// files. `descriptor.source` is never touched by this factory, so which
/// real catalog descriptor a test uses only matters for `delete()`, which
/// does still hit the real filesystem (see the note on the descriptor
/// properties below).
@MainActor
private final class FakeModelEngineFactory {
    let log = EventLog()
    private(set) var createdEngines: [String: [FakeModelEngine]] = [:]
    var errorForID: [String: Error] = [:]
    var gateForID: [String: Gate] = [:]

    func make(_ descriptor: ModelDescriptor, onProgress: @escaping @Sendable (Double) -> Void) -> TranscriptionEngine {
        let sequence = createdEngines[descriptor.id]?.count ?? 0
        let engine = FakeModelEngine(id: "\(descriptor.id)#\(sequence)", kind: descriptor.engineKind, log: log)
        engine.loadError = errorForID[descriptor.id]
        engine.gate = gateForID[descriptor.id]
        createdEngines[descriptor.id, default: []].append(engine)
        return engine
    }

    /// The most recently created engine for a descriptor id — the one
    /// currently in play, since `ModelManager` never reuses an instance.
    func latest(_ id: String) -> FakeModelEngine? {
        createdEngines[id]?.last
    }
}

/// Reference-type box for the fake "is this on disk" state, so the
/// `isInstalled` closure captured at `ModelManager.init` sees later
/// mutations rather than a snapshot from closure-creation time.
private final class InstalledSet {
    var ids: Set<String> = []
}

// MARK: - Tests

@MainActor
final class ModelManagerTests: XCTestCase {
    private var factory: FakeModelEngineFactory!
    private var installed: InstalledSet!
    private var prefs: Preferences!
    private let suiteName = "DogballWhisperTests.ModelManager"

    // Real catalog descriptors, used only for their id/source identity — the
    // injected engine factory means install/makeActive never touch a real
    // engine or the network. `delete()` still routes by `descriptor.source`
    // to real `ModelMirror`/`FileManager` calls, though, and `.parakeetMirror`
    // always operates on the one real Parakeet directory regardless of which
    // descriptor triggered it (already downloaded on this machine from an
    // earlier task) — so no test here ever calls `delete()` on a Parakeet
    // descriptor. The two Whisper variants used below (tiny.en, large v3
    // turbo) are never downloaded by this suite, so `delete()`'s real
    // filesystem call is a harmless no-op against a path that does not exist.
    private var whisperTiny: ModelDescriptor { ModelCatalog.descriptor(id: "whisper-tiny-en")! }
    private var whisperLarge: ModelDescriptor { ModelCatalog.descriptor(id: "whisper-large-v3-turbo")! }

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        factory = FakeModelEngineFactory()
        installed = InstalledSet()
        prefs = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeManager() -> ModelManager {
        ModelManager(
            preferences: prefs,
            engineFactory: factory.make,
            isInstalled: { [installed] descriptor in installed!.ids.contains(descriptor.id) }
        )
    }

    // MARK: One download at a time

    func testSecondInstallWhileOneIsInFlightIsRefused() async {
        let gate = Gate()
        factory.gateForID[whisperTiny.id] = gate
        let manager = makeManager()

        let firstInstall = Task { try? await manager.install(whisperTiny) }
        var attempts = 0
        while !manager.isBusy && attempts < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts += 1
        }
        XCTAssertTrue(manager.isBusy)

        try? await manager.install(whisperLarge)
        XCTAssertNil(
            factory.latest(whisperLarge.id),
            "a second install must not even construct an engine while one is in flight")

        await gate.open()
        _ = await firstInstall.value
        XCTAssertFalse(manager.isBusy)
    }

    func testDeleteRefusesWhileTheSameModelIsInstalling() async {
        let gate = Gate()
        factory.gateForID[whisperTiny.id] = gate
        let manager = makeManager()

        let installTask = Task { try? await manager.install(whisperTiny) }
        var attempts = 0
        while manager.progress[whisperTiny.id] == nil && attempts < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts += 1
        }
        XCTAssertNotNil(manager.progress[whisperTiny.id])

        XCTAssertThrowsError(try manager.delete(whisperTiny)) { error in
            XCTAssertEqual(error as? ModelManagerError, .deletingWhileInstalling)
        }

        await gate.open()
        _ = await installTask.value
    }

    // MARK: First install becomes active

    func testFirstSuccessfulInstallBecomesActive() async throws {
        let manager = makeManager()
        XCTAssertNil(manager.activeModelID)

        try await manager.install(whisperTiny)

        XCTAssertEqual(manager.activeModelID, whisperTiny.id)
        let engines = factory.createdEngines[whisperTiny.id] ?? []
        XCTAssertEqual(engines.count, 2, "install probes with one engine, then makeActive loads a second")
        XCTAssertEqual(engines[0].loadCount, 1)
        XCTAssertEqual(
            engines[0].unloadCount, 1,
            "the install probe engine must be unloaded once it proved the model downloads")
        XCTAssertEqual(engines[1].loadCount, 1)
        XCTAssertEqual(engines[1].unloadCount, 0, "the engine that becomes active must stay loaded")
        XCTAssertTrue(manager.activeEngine === engines[1])
    }

    // MARK: Delete

    func testDeletingTheActiveModelClearsEngineAndID() async throws {
        let manager = makeManager()
        try await manager.install(whisperTiny)
        let activeEngine = factory.latest(whisperTiny.id)
        XCTAssertNotNil(manager.activeEngine)

        try manager.delete(whisperTiny)

        XCTAssertNil(manager.activeModelID)
        XCTAssertNil(manager.activeEngine)
        XCTAssertEqual(activeEngine?.unloadCount, 1)
    }

    // MARK: makeActive

    func testMakeActiveUnloadsThePreviousEngineBeforeLoadingTheNew() async throws {
        let manager = makeManager()
        try await manager.install(whisperTiny)
        let previousEngine = try XCTUnwrap(factory.latest(whisperTiny.id))

        try await manager.makeActive(whisperLarge)

        let newEngine = try XCTUnwrap(factory.latest(whisperLarge.id))
        let unloadIndex = try XCTUnwrap(factory.log.events.firstIndex(of: "unloaded:\(previousEngine.id)"))
        let loadIndex = try XCTUnwrap(factory.log.events.firstIndex(of: "loaded:\(newEngine.id)"))
        XCTAssertLessThan(
            unloadIndex, loadIndex,
            "the previous engine must be unloaded before the new one finishes loading")
        XCTAssertTrue(manager.activeEngine === newEngine)
    }

    // A failed makeActive must leave the manager coherent: activeModelID
    // names a model whose engine is actually loaded, or nothing at all.
    func testFailedMakeActiveRestoresThePreviousActiveModel() async throws {
        let manager = makeManager()
        try await manager.install(whisperTiny)
        installed.ids.insert(whisperTiny.id)
        let originalActiveEngine = factory.latest(whisperTiny.id)

        factory.errorForID[whisperLarge.id] = FakeLoadError()

        do {
            try await manager.makeActive(whisperLarge)
            XCTFail("expected the load failure to propagate")
        } catch {
            XCTAssertTrue(error is FakeLoadError)
        }

        XCTAssertEqual(manager.activeModelID, whisperTiny.id)
        XCTAssertNotNil(manager.activeEngine)
        XCTAssertEqual(manager.activeEngine?.isLoaded, true)
        XCTAssertTrue(
            manager.activeEngine !== originalActiveEngine,
            "the original engine was already unloaded; the rollback must construct a fresh one")
    }

    func testFailedMakeActiveWithNoPreviousModelClearsTheSelection() async {
        let manager = makeManager()
        XCTAssertNil(manager.activeModelID)
        factory.errorForID[whisperLarge.id] = FakeLoadError()

        do {
            try await manager.makeActive(whisperLarge)
            XCTFail("expected the load failure to propagate")
        } catch {
            XCTAssertTrue(error is FakeLoadError)
        }

        XCTAssertNil(manager.activeModelID, "there is nothing to roll back to, so the selection must stay nil")
        XCTAssertNil(manager.activeEngine)
    }

    // If the rollback reload also fails there truly is no working model;
    // the selection must not dangle pointing at one with no live engine.
    func testFailedMakeActiveWhereThePreviousReloadAlsoFailsClearsTheSelection() async throws {
        let manager = makeManager()
        try await manager.install(whisperTiny)
        installed.ids.insert(whisperTiny.id)

        factory.errorForID[whisperLarge.id] = FakeLoadError()
        do {
            try await manager.makeActive(whisperLarge)
            XCTFail("expected the load failure to propagate")
        } catch {}
        XCTAssertEqual(manager.activeModelID, whisperTiny.id, "the first failure should have rolled back cleanly")

        // Now the previously-working model is broken too: its reload during
        // rollback will also fail.
        factory.errorForID[whisperTiny.id] = FakeLoadError()
        do {
            try await manager.makeActive(whisperLarge)
            XCTFail("expected the load failure to propagate")
        } catch {}

        XCTAssertNil(
            manager.activeModelID,
            "if even the rollback reload fails there is no active model, so the selection must not dangle")
        XCTAssertNil(manager.activeEngine)
    }

    // MARK: Progress

    func testProgressIsClearedAfterASuccessfulInstall() async throws {
        let manager = makeManager()
        try await manager.install(whisperTiny)
        XCTAssertNil(manager.progress[whisperTiny.id], "the UI must not show a stuck progress bar after success")
    }

    func testProgressIsClearedAfterAFailedInstall() async {
        let manager = makeManager()
        factory.errorForID[whisperTiny.id] = FakeLoadError()

        do {
            try await manager.install(whisperTiny)
            XCTFail("expected the load failure to propagate")
        } catch {
            XCTAssertTrue(error is FakeLoadError)
        }

        XCTAssertNil(manager.progress[whisperTiny.id], "the UI must not show a stuck progress bar after failure")
    }
}
