import XCTest
@testable import DogballWhisper

@MainActor
final class SkeletonTests: XCTestCase {
    func testMenuBarControllerCreatesAStatusItemWithAMenu() {
        let controller = MenuBarController(onOpenSettings: {}, onFinishSetup: {})
        XCTAssertNotNil(controller.statusItem.button)
        XCTAssertEqual(controller.statusItem.menu?.items.count, 8)
    }

    func testFinishSetupItemOnlyShowsWhileSetupIsIncomplete() {
        let controller = MenuBarController(onOpenSettings: {}, onFinishSetup: {})
        guard let items = controller.statusItem.menu?.items, items.count >= 2 else {
            return XCTFail("expected the finish-setup item and its separator")
        }
        // Hidden by default: most launches finish setup before the menu is ever opened.
        XCTAssertTrue(items[0].isHidden)
        XCTAssertTrue(items[1].isHidden)

        controller.setSetupIncomplete(true)
        XCTAssertFalse(items[0].isHidden)
        XCTAssertFalse(items[1].isHidden)

        controller.setSetupIncomplete(false)
        XCTAssertTrue(items[0].isHidden)
        XCTAssertTrue(items[1].isHidden)
    }
}
