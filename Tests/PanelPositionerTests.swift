import XCTest
@testable import DogballWhisper

final class PanelPositionerTests: XCTestCase {
    // A 1440x900 main display. Cocoa origin is bottom-left; AX rects are
    // top-left, so primaryScreenMaxY is what converts between them.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let primaryMaxY: CGFloat = 900
    private let size = PanelPositioner.panelSize

    private func origin(caret: CGRect?) -> CGPoint {
        PanelPositioner.origin(
            panelSize: size,
            caretRectQuartz: caret,
            screenFrame: screen,
            primaryScreenMaxY: primaryMaxY
        )
    }

    func testWithoutACaretThePanelSitsNearTheBottomCenter() {
        let point = origin(caret: nil)
        XCTAssertEqual(point.x, (1440 - size.width) / 2, accuracy: 0.5)
        XCTAssertEqual(point.y, screen.minY + PanelPositioner.bottomInset, accuracy: 0.5)
    }

    // A caret 300pt down from the top of a 900pt screen is at Cocoa y=600;
    // the panel's bottom edge goes a gap above the caret's top edge.
    func testPanelFloatsJustAboveTheCaret() {
        let caret = CGRect(x: 500, y: 300, width: 1, height: 18)
        let point = origin(caret: caret)
        XCTAssertEqual(point.x, 500 - size.width / 2, accuracy: 0.5)
        XCTAssertEqual(point.y, 600 + PanelPositioner.caretGap, accuracy: 0.5)
    }

    // Near the top of the screen there is no room above, so it goes below
    // instead of being clipped off-screen.
    func testPanelFlipsBelowTheCaretWhenThereIsNoRoomAbove() {
        let caret = CGRect(x: 700, y: 10, width: 1, height: 18)
        let point = origin(caret: caret)
        let caretBottomCocoa = primaryMaxY - (10 + 18)
        XCTAssertEqual(point.y, caretBottomCocoa - size.height - PanelPositioner.caretGap, accuracy: 0.5)
    }

    func testPanelIsClampedInsideTheScreenHorizontally() {
        XCTAssertEqual(origin(caret: CGRect(x: 2, y: 400, width: 1, height: 18)).x,
                       screen.minX + PanelPositioner.edgeInset, accuracy: 0.5)
        XCTAssertEqual(origin(caret: CGRect(x: 1438, y: 400, width: 1, height: 18)).x,
                       screen.maxX - size.width - PanelPositioner.edgeInset, accuracy: 0.5)
    }

    // A zero rect is what some apps report instead of nothing at all.
    func testZeroCaretRectIsTreatedAsNoCaret() {
        XCTAssertEqual(origin(caret: .zero), origin(caret: nil))
    }

    // Second display to the right of the primary one.
    func testCaretOnASecondaryDisplayStaysOnThatDisplay() {
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let point = PanelPositioner.origin(
            panelSize: size,
            caretRectQuartz: CGRect(x: 2000, y: 500, width: 1, height: 18),
            screenFrame: secondary,
            primaryScreenMaxY: primaryMaxY
        )
        XCTAssertGreaterThanOrEqual(point.x, secondary.minX)
        XCTAssertLessThanOrEqual(point.x + size.width, secondary.maxX)
    }

    // A display arranged above the primary. Quartz y runs downward from the
    // primary's top edge, so a caret up on that display converts to a
    // negative Quartz y — this exercises the flip subtraction with a
    // negative input rather than just a positive one on a shifted display.
    func testCaretOnADisplayAboveThePrimaryUsesNegativeQuartzCoordinates() {
        let secondary = CGRect(x: 0, y: 900, width: 1440, height: 900)
        // Cocoa y 1350 on that display is Quartz y = primaryMaxY - 1350 = -450.
        let caret = CGRect(x: 500, y: -450, width: 1, height: 18)
        let point = PanelPositioner.origin(
            panelSize: size,
            caretRectQuartz: caret,
            screenFrame: secondary,
            primaryScreenMaxY: primaryMaxY
        )
        XCTAssertGreaterThanOrEqual(point.x, secondary.minX)
        XCTAssertLessThanOrEqual(point.x + size.width, secondary.maxX)
        XCTAssertGreaterThanOrEqual(point.y, secondary.minY)
        XCTAssertLessThanOrEqual(point.y + size.height, secondary.maxY)
    }

    // A caret taller than the panel itself (e.g. a multi-line text field)
    // must not push the panel off screen.
    func testTallCaretRectStillLandsInsideTheScreen() {
        let caret = CGRect(x: 700, y: 10, width: 1, height: 80)
        let point = origin(caret: caret)
        XCTAssertGreaterThanOrEqual(point.x, screen.minX)
        XCTAssertLessThanOrEqual(point.x + size.width, screen.maxX)
        XCTAssertGreaterThanOrEqual(point.y, screen.minY)
        XCTAssertLessThanOrEqual(point.y + size.height, screen.maxY)
    }
}
