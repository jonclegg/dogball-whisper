import XCTest
@testable import DogballWhisper

final class SkeletonTests: XCTestCase {
    func testMenuBarControllerCreatesAStatusItemWithAMenu() {
        let controller = MenuBarController()
        XCTAssertNotNil(controller.statusItem.button)
        XCTAssertEqual(controller.statusItem.menu?.items.count, 1)
    }
}
