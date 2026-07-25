import XCTest
@testable import DogballWhisper

/// Real models, real audio, real download. Opt-in because the first run pulls
/// ~500MB: RUN_ENGINE_IT=1 ./scripts/test.sh DogballWhisperTests/EngineIntegrationTests
final class EngineIntegrationTests: XCTestCase {

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle(for: EngineIntegrationTests.self)
            .url(forResource: "hello", withExtension: "wav"))
    }

    func testParakeetTranscribesTheFixture() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_ENGINE_IT"] == "1")
        let engine = ParakeetEngine()
        try await engine.load()
        XCTAssertTrue(engine.isLoaded)

        let text = try await engine.transcribe(try fixtureURL())
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.lowercased().contains("hello"), "got: \(text)")
    }

    func testTranscribingBeforeLoadingThrows() async {
        let engine = ParakeetEngine()
        do {
            _ = try await engine.transcribe(URL(fileURLWithPath: "/dev/null"))
            XCTFail("expected notLoaded")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .notLoaded)
        }
    }
}
