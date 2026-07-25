import XCTest
@testable import DogballWhisper

final class ModelCatalogTests: XCTestCase {

    func testCatalogListsParakeetAndFourWhisperModels() {
        XCTAssertEqual(ModelCatalog.all.count, 5)
        XCTAssertEqual(ModelCatalog.all.filter { $0.engineKind == .parakeet }.count, 1)
        XCTAssertEqual(ModelCatalog.all.filter { $0.engineKind == .whisper }.count, 4)
    }

    func testEveryDescriptorHasAUniqueIDAndANonZeroSize() {
        let ids = ModelCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ModelCatalog.all.allSatisfy { $0.sizeBytes > 0 })
    }

    func testDefaultModelIsParakeet() {
        let descriptor = ModelCatalog.descriptor(id: ModelCatalog.defaultModelID)
        XCTAssertEqual(descriptor?.engineKind, .parakeet)
    }

    func testLookupOfAnUnknownIDReturnsNil() {
        XCTAssertNil(ModelCatalog.descriptor(id: "nope"))
    }

    // Whisper models live under our own Application Support directory rather
    // than ~/Documents, which is where WhisperKit would put them by default.
    func testWhisperModelsLiveUnderApplicationSupport() throws {
        let whisper = try XCTUnwrap(ModelCatalog.all.first { $0.engineKind == .whisper })
        let path = ModelCatalog.installedLocation(for: whisper).path
        XCTAssertTrue(path.contains("Application Support/DogballWhisper/Models"), path)
        XCTAssertTrue(path.hasSuffix("argmaxinc/whisperkit-coreml/\(whisperVariant(whisper))"), path)
    }

    private func whisperVariant(_ descriptor: ModelDescriptor) -> String {
        guard case let .whisperKit(variant) = descriptor.source else { return "" }
        return variant
    }

    func testStateReportsActiveDownloadingAndNotInstalled() throws {
        let descriptor = try XCTUnwrap(ModelCatalog.descriptor(id: ModelCatalog.defaultModelID))

        XCTAssertEqual(
            ModelCatalog.state(for: descriptor, activeID: nil, progress: [descriptor.id: 0.4]),
            .downloading(0.4))

        // Not installed on disk, so neither "active" nor "installed" can apply.
        if !ModelCatalog.isInstalled(descriptor) {
            XCTAssertEqual(
                ModelCatalog.state(for: descriptor, activeID: descriptor.id, progress: [:]),
                .notInstalled)
        }
    }
}
