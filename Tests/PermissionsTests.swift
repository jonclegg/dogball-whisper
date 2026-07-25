import XCTest
@testable import DogballWhisper

final class PermissionsTests: XCTestCase {

    // Accessibility is optional: without it we degrade to clipboard-only
    // insertion rather than refusing to run.
    func testOnlyMicrophoneAndInputMonitoringAreRequired() {
        XCTAssertTrue(PermissionKind.microphone.isRequired)
        XCTAssertTrue(PermissionKind.inputMonitoring.isRequired)
        XCTAssertFalse(PermissionKind.accessibility.isRequired)
    }

    func testEveryPermissionHasUserFacingCopy() {
        for kind in PermissionKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.explanation.isEmpty)
        }
    }

    func testSettingsDeepLinksPointAtThePrivacyPanes() {
        XCTAssertTrue(
            Permissions.settingsURL(for: .inputMonitoring).absoluteString
                .contains("Privacy_ListenEvent"))
        XCTAssertTrue(
            Permissions.settingsURL(for: .accessibility).absoluteString
                .contains("Privacy_Accessibility"))
        XCTAssertTrue(
            Permissions.settingsURL(for: .microphone).absoluteString
                .contains("Privacy_Microphone"))
    }

    func testSummaryNamesWhatIsStillMissing() {
        XCTAssertEqual(Permissions.summary(granted: []), "Microphone and Input Monitoring needed")
        XCTAssertEqual(Permissions.summary(granted: [.microphone]), "Input Monitoring needed")
        XCTAssertEqual(
            Permissions.summary(granted: [.microphone, .inputMonitoring]),
            "Ready")
    }

    // 0 means "Do Nothing", which is the only value that leaves fn to us.
    func testFnUsageValuesOtherThanDoNothingCountAsClaimed() {
        XCTAssertFalse(Permissions.fnUsageIsClaimed(0))
        XCTAssertTrue(Permissions.fnUsageIsClaimed(1))
        XCTAssertTrue(Permissions.fnUsageIsClaimed(2))
        XCTAssertTrue(Permissions.fnUsageIsClaimed(3))
    }
}
