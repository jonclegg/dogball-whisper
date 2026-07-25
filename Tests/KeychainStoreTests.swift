import XCTest
@testable import DogballWhisper

/// The app's only secret, and the only store it lives in.
///
/// Every case here runs against its own service/account, never
/// `Location.openRouterAPIKey`, so running the suite can neither read nor
/// overwrite the key the machine is actually dictating with.
final class KeychainStoreTests: XCTestCase {
    private let location = KeychainStore.Location(
        service: "com.jonclegg.DogballWhisper.tests", account: "keychain-store-tests")

    override func setUp() {
        super.setUp()
        KeychainStore.delete(at: location)
    }

    override func tearDown() {
        KeychainStore.delete(at: location)
        super.tearDown()
    }

    func testSavingThenReadingRoundTrips() {
        XCTAssertTrue(KeychainStore.save("sk-or-v1-abc123", at: location))
        XCTAssertEqual(KeychainStore.read(at: location), "sk-or-v1-abc123")
    }

    func testSavingOverAnExistingKeyReplacesIt() {
        KeychainStore.save("first", at: location)
        XCTAssertTrue(KeychainStore.save("second", at: location))
        XCTAssertEqual(KeychainStore.read(at: location), "second")
    }

    // Onboarding calls `save` unconditionally on "Start dictating", so an
    // empty save must not be able to wipe a working key.
    func testSavingAnEmptyStringLeavesAnExistingKeyAlone() {
        KeychainStore.save("sk-or-v1-abc123", at: location)
        XCTAssertTrue(KeychainStore.save("", at: location))
        XCTAssertEqual(KeychainStore.read(at: location), "sk-or-v1-abc123")
    }

    func testDeleteRemovesTheKeyAndReadingAfterwardsReturnsNil() {
        KeychainStore.save("sk-or-v1-abc123", at: location)
        XCTAssertTrue(KeychainStore.delete(at: location))
        XCTAssertNil(KeychainStore.read(at: location))
    }

    func testReadingWhenNothingWasEverStoredReturnsNil() {
        XCTAssertNil(KeychainStore.read(at: location))
    }

    func testDeletingWhenNothingIsStoredStillReportsNoKeyStored() {
        XCTAssertTrue(KeychainStore.delete(at: location))
    }

    // The revocation path. Clearing the field in Settings has to actually
    // remove the key, or a user who deletes it to stop sending their
    // dictation to a third party keeps sending it.
    func testAnEmptiedFieldRevokesTheStoredKey() {
        KeychainStore.save("sk-or-v1-abc123", at: location)
        KeychainStore.setKey(fromField: "", at: location)
        XCTAssertNil(KeychainStore.read(at: location))
    }

    func testAWhitespaceOnlyFieldAlsoRevokes() {
        KeychainStore.save("sk-or-v1-abc123", at: location)
        KeychainStore.setKey(fromField: "   \n ", at: location)
        XCTAssertNil(KeychainStore.read(at: location))
    }

    func testAFieldWithAKeyInItStoresTheKeyTrimmed() {
        KeychainStore.setKey(fromField: "  sk-or-v1-abc123\n", at: location)
        XCTAssertEqual(KeychainStore.read(at: location), "sk-or-v1-abc123")
    }
}
