import XCTest
@testable import DogballWhisper

final class PermissionsTests: XCTestCase {

    // Accessibility carries both the keyboard event tap and the paste, so it
    // is required. Input Monitoring is not: a session event tap does not need
    // it, and macOS will not list an app there until it installs a tap, so
    // requiring it made first-run setup impossible to complete.
    func testOnlyMicrophoneAndAccessibilityAreRequired() {
        XCTAssertTrue(PermissionKind.microphone.isRequired)
        XCTAssertTrue(PermissionKind.accessibility.isRequired)
        XCTAssertFalse(PermissionKind.inputMonitoring.isRequired)
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
        XCTAssertEqual(Permissions.summary(granted: []), "Microphone and Accessibility needed")
        XCTAssertEqual(Permissions.summary(granted: [.microphone]), "Accessibility needed")
        XCTAssertEqual(
            Permissions.summary(granted: [.microphone, .accessibility]),
            "Ready")
    }

    // Input Monitoring must never hold setup back, however it is toggled.
    func testInputMonitoringNeverBlocksReadiness() {
        XCTAssertEqual(
            Permissions.summary(granted: [.microphone, .accessibility]), "Ready")
        XCTAssertEqual(
            Permissions.summary(granted: [.microphone, .accessibility, .inputMonitoring]),
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
