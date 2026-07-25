import XCTest
@testable import DogballWhisper

final class ModelMirrorIntegrationTests: XCTestCase {

    // The manifest is what makes byte-accurate progress and the size check
    // possible, so a malformed or unbundled manifest must fail loudly here
    // rather than halfway through a 483MB download.
    func testBundledManifestIsUsable() throws {
        let manifest = try ModelMirror.loadManifest()
        XCTAssertFalse(manifest.prefix.isEmpty)
        XCTAssertFalse(manifest.files.isEmpty)
        XCTAssertEqual(manifest.files.reduce(0) { $0 + $1.size }, manifest.totalBytes)
        XCTAssertTrue(manifest.files.allSatisfy { $0.size > 0 && !$0.path.isEmpty })
    }

    func testModelsDirectoryIsFluidAudiosCacheLocation() throws {
        let path = ModelMirror.modelsDirectory(prefix: "some-model").path
        XCTAssertTrue(path.contains("Application Support/FluidAudio/Models/some-model"), path)
    }

    // Live download against CloudFront. Reports progress, verifies every file's
    // size, and resumes rather than restarting when files are already present.
    // Run with: RUN_MIRROR_IT=1 ./scripts/test.sh DogballWhisperTests/ModelMirrorIntegrationTests
    func testMirrorDownloadsThenReportsCompleteAndResumesInstantly() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_MIRROR_IT"] == "1",
            "Set RUN_MIRROR_IT=1 to run the live mirror download test")

        var fractions: [Double] = []
        try await ModelMirror.download { fractions.append($0) }

        XCTAssertTrue(ModelMirror.isComplete())
        XCTAssertEqual(fractions.last, 1.0)
        XCTAssertEqual(fractions, fractions.sorted(), "progress must not go backwards")

        // Second pass: everything is on disk, so it should finish immediately
        // and still report completion.
        var resumed: [Double] = []
        try await ModelMirror.download { resumed.append($0) }
        XCTAssertEqual(resumed.last, 1.0)
    }
}
