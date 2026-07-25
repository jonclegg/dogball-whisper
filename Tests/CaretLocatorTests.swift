import XCTest
@testable import DogballWhisper

/// The AX calls in `CaretLocator` need a real focused app and cannot run
/// here, so this covers the pure geometry factored out for exactly that
/// reason: the plausibility band tiers 1/2 are held to, and the synthesized
/// sliver tier 3 falls back to.
final class CaretLocatorTests: XCTestCase {
    // MARK: - isPlausibleCaretRect

    func testAnOrdinaryCaretHeightIsPlausible() {
        XCTAssertTrue(CaretLocator.isPlausibleCaretRect(CGRect(x: 0, y: 0, width: 1, height: 18)))
    }

    func testAWholeDocumentRectIsNotPlausible() {
        XCTAssertFalse(CaretLocator.isPlausibleCaretRect(CGRect(x: 0, y: 0, width: 800, height: 900)))
    }

    func testAZeroHeightRectIsNotPlausible() {
        XCTAssertFalse(CaretLocator.isPlausibleCaretRect(CGRect(x: 0, y: 0, width: 1, height: 0)))
    }

    func testHeightsAtTheBandEdgesAreInclusiveJustOutsideIsNot() {
        XCTAssertTrue(CaretLocator.isPlausibleCaretRect(CGRect(x: 0, y: 0, width: 1, height: 2)))
        XCTAssertTrue(CaretLocator.isPlausibleCaretRect(CGRect(x: 0, y: 0, width: 1, height: 160)))
        XCTAssertFalse(CaretLocator.isPlausibleCaretRect(CGRect(x: 0, y: 0, width: 1, height: 1.9)))
        XCTAssertFalse(CaretLocator.isPlausibleCaretRect(CGRect(x: 0, y: 0, width: 1, height: 161)))
    }

    // MARK: - caretRect(fromElementOrigin:size:)

    func testElementFrameSynthesizesASliverNotTheWholeFrame() {
        let rect = CaretLocator.caretRect(
            fromElementOrigin: CGPoint(x: 100, y: 200), size: CGSize(width: 300, height: 40))
        XCTAssertNotNil(rect)
        XCTAssertEqual(rect!.width, 1)
        XCTAssertEqual(rect!.origin.x, 104)
        XCTAssertEqual(rect!.origin.y, 204)
        XCTAssertTrue(CaretLocator.isPlausibleCaretRect(rect!))
    }

    // A whole AXWebArea (or any other giant frame reached when descent
    // failed to find a real leaf) must still come back inside the
    // plausible band instead of being rejected outright — that is the
    // entire point of tier 3 existing.
    func testAGiantElementFrameIsClampedIntoThePlausibleBand() {
        let rect = CaretLocator.caretRect(
            fromElementOrigin: CGPoint(x: 0, y: 0), size: CGSize(width: 1920, height: 5000))
        XCTAssertNotNil(rect)
        XCTAssertTrue(CaretLocator.isPlausibleCaretRect(rect!))
        XCTAssertEqual(rect!.height, CaretLocator.plausibleCaretHeightRange.upperBound)
    }

    // A short field (a one-line search box, say) below the 18pt floor
    // still gets a usable, non-degenerate sliver rather than a near-zero
    // height rect.
    func testATinyElementFrameIsRaisedToAUsableMinimum() {
        let rect = CaretLocator.caretRect(
            fromElementOrigin: .zero, size: CGSize(width: 40, height: 4))
        XCTAssertNotNil(rect)
        XCTAssertEqual(rect!.height, 18)
    }

    func testAZeroSizeFrameYieldsNoRect() {
        XCTAssertNil(CaretLocator.caretRect(fromElementOrigin: .zero, size: .zero))
    }

    func testANonFiniteFrameYieldsNoRectRatherThanTrapping() {
        XCTAssertNil(
            CaretLocator.caretRect(
                fromElementOrigin: CGPoint(x: CGFloat.nan, y: 0), size: CGSize(width: 40, height: 20)))
        XCTAssertNil(
            CaretLocator.caretRect(
                fromElementOrigin: .zero, size: CGSize(width: CGFloat.infinity, height: 20)))
    }

    // MARK: - CaretLocation

    func testUnknownLocationHasNoRectNoPIDAndIsNotASecureField() {
        XCTAssertNil(CaretLocation.unknown.rectQuartz)
        XCTAssertNil(CaretLocation.unknown.pid)
        XCTAssertFalse(CaretLocation.unknown.isSecureField)
    }

    func testSecureFieldDefaultsToFalseWhenNotSpecified() {
        let location = CaretLocation(rectQuartz: nil, pid: 123)
        XCTAssertFalse(location.isSecureField)
    }
}
