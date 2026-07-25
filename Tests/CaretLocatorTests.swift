import XCTest
@testable import DogballWhisper

/// The AX calls in `CaretLocator` need a real focused app and cannot run
/// here, so this covers everything factored out for exactly that reason:
/// the plausibility band tiers 1/2 are held to, the synthesized sliver tier
/// 3 falls back to, the on-screen test that keeps tier 3 from placing the
/// panel off every display, which bundles are allowed to be nudged, and the
/// budget that keeps the tree walk off the user's first syllable.
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

    func testElementFrameSynthesizesASliverNotTheWholeFrame() throws {
        let rect = try XCTUnwrap(
            CaretLocator.caretRect(
                fromElementOrigin: CGPoint(x: 100, y: 200), size: CGSize(width: 300, height: 40)))
        XCTAssertEqual(rect.width, 1)
        XCTAssertEqual(rect.origin.x, 104)
        XCTAssertEqual(rect.origin.y, 204)
        XCTAssertTrue(CaretLocator.isPlausibleCaretRect(rect))
    }

    // A whole AXWebArea (or any other giant frame reached when descent
    // failed to find a real leaf) must still come back inside the
    // plausible band instead of being rejected outright — that is the
    // entire point of tier 3 existing.
    func testAGiantElementFrameIsClampedIntoThePlausibleBand() throws {
        let rect = try XCTUnwrap(
            CaretLocator.caretRect(
                fromElementOrigin: CGPoint(x: 0, y: 0), size: CGSize(width: 1920, height: 5000)))
        XCTAssertTrue(CaretLocator.isPlausibleCaretRect(rect))
        XCTAssertEqual(rect.height, CaretLocator.plausibleCaretHeightRange.upperBound)
    }

    // A short field (a one-line search box, say) below the 18pt floor
    // still gets a usable, non-degenerate sliver rather than a near-zero
    // height rect.
    func testATinyElementFrameIsRaisedToAUsableMinimum() throws {
        let rect = try XCTUnwrap(
            CaretLocator.caretRect(fromElementOrigin: .zero, size: CGSize(width: 40, height: 4)))
        XCTAssertEqual(rect.height, 18)
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

    // MARK: - isOnScreen
    //
    // Tier 3 will happily report a rect for an element scrolled out of every
    // display; the panel would then be clamped to some arbitrary screen edge
    // instead of using the predictable bottom-center fallback.

    private let primaryMaxY: CGFloat = 1000
    private let primary = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    func testARectOnThePrimaryScreenIsOnScreen() {
        // Quartz y=100 from the top is Cocoa y=880 on a 1000pt-tall primary.
        XCTAssertTrue(
            CaretLocator.isOnScreen(
                quartzRect: CGRect(x: 200, y: 100, width: 1, height: 20),
                screenFramesCocoa: [primary], primaryScreenMaxY: primaryMaxY))
    }

    func testARectScrolledOffEveryDisplayIsNotOnScreen() {
        XCTAssertFalse(
            CaretLocator.isOnScreen(
                quartzRect: CGRect(x: 200, y: -4000, width: 1, height: 20),
                screenFramesCocoa: [primary], primaryScreenMaxY: primaryMaxY))
        XCTAssertFalse(
            CaretLocator.isOnScreen(
                quartzRect: CGRect(x: 9000, y: 100, width: 1, height: 20),
                screenFramesCocoa: [primary], primaryScreenMaxY: primaryMaxY))
    }

    // A caret on a second display to the left (negative Cocoa x) is on
    // screen, and must not be thrown away by a primary-screen-only test.
    func testARectOnASecondaryDisplayIsOnScreen() {
        let secondary = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        XCTAssertTrue(
            CaretLocator.isOnScreen(
                quartzRect: CGRect(x: -700, y: 300, width: 1, height: 20),
                screenFramesCocoa: [primary, secondary], primaryScreenMaxY: primaryMaxY))
    }

    func testNoScreensMeansNothingIsOnScreen() {
        XCTAssertFalse(
            CaretLocator.isOnScreen(
                quartzRect: CGRect(x: 200, y: 100, width: 1, height: 20),
                screenFramesCocoa: [], primaryScreenMaxY: 0))
    }

    // MARK: - Chromium/Electron detection
    //
    // What decides whether an app gets `AXEnhancedUserInterface` set on it.
    // Native AppKit apps must not: it is the flag VoiceOver sets, it changes
    // window-resize and animation behavior, and it is never unset.

    private func makeBundle(frameworkNames: [String]?) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogball-\(UUID().uuidString).app")
        if let frameworkNames {
            let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
            try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
            for name in frameworkNames {
                try FileManager.default.createDirectory(
                    at: frameworks.appendingPathComponent(name), withIntermediateDirectories: true)
            }
        } else {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: bundle) }
        return bundle
    }

    func testAnElectronBundleLooksChromiumOrElectron() throws {
        let bundle = try makeBundle(frameworkNames: [
            "Electron Framework.framework", "Squirrel.framework",
        ])
        XCTAssertTrue(CaretLocator.looksChromiumOrElectron(bundleURL: bundle))
    }

    func testAChromiumBundleLooksChromiumOrElectron() throws {
        let bundle = try makeBundle(frameworkNames: ["Google Chrome Framework.framework"])
        XCTAssertTrue(CaretLocator.looksChromiumOrElectron(bundleURL: bundle))
    }

    func testANativeAppBundleDoesNot() throws {
        XCTAssertFalse(
            CaretLocator.looksChromiumOrElectron(
                bundleURL: try makeBundle(frameworkNames: ["Sparkle.framework"])))
        XCTAssertFalse(
            CaretLocator.looksChromiumOrElectron(bundleURL: try makeBundle(frameworkNames: nil)))
        XCTAssertFalse(CaretLocator.looksChromiumOrElectron(bundleURL: nil))
    }

    // MARK: - Walk bounds

    // The descent runs on the main actor while the user is already talking,
    // and every node it visits is several cross-process round trips. Depth
    // alone does not bound it; these do.
    func testTheDescentBudgetStaysSmallEnoughForTheHotPath() {
        XCTAssertLessThanOrEqual(CaretLocator.maxDescendNodes, 60)
        XCTAssertLessThanOrEqual(CaretLocator.maxDescendDuration, 0.015)
        XCTAssertLessThanOrEqual(CaretLocator.messagingTimeout, 0.05)
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

    // MARK: - caretAnchor

    // A native text field answers a collapsed selection with a zero-width
    // rect, so both edges are the caret and the anchor is unambiguous.
    func testACollapsedRectAnchorsAtItsOwnPosition() {
        let anchored = CaretLocator.caretAnchor(
            for: CGRect(x: 19, y: 885, width: 0, height: 17))
        XCTAssertEqual(anchored.minX, 19)
        XCTAssertEqual(anchored.minY, 885)
        XCTAssertEqual(anchored.height, 17)
    }

    // Some implementations report the character behind the caret, where the
    // trailing edge is the insertion point.
    func testASingleCharacterWideRectAnchorsOnItsTrailingEdge() {
        let anchored = CaretLocator.caretAnchor(
            for: CGRect(x: 100, y: 200, width: 8, height: 17))
        XCTAssertEqual(anchored.minX, 108)
    }

    // Measured in a browser compose box: WebKit answers a collapsed marker
    // range with the whole line. Anchoring on the trailing edge put the panel
    // 427pt away at the field's right margin.
    func testAWholeLineRectAnchorsOnItsLeadingEdge() {
        let anchored = CaretLocator.caretAnchor(
            for: CGRect(x: 731, y: 882, width: 427, height: 20))
        XCTAssertEqual(anchored.minX, 731)
        XCTAssertEqual(anchored.minY, 882)
    }

    func testTheAnchorSwitchesEdgesAtTheCaretWidthThreshold() {
        let atThreshold = CaretLocator.caretAnchor(
            for: CGRect(x: 50, y: 0, width: CaretLocator.maxCaretLikeWidth, height: 17))
        XCTAssertEqual(atThreshold.minX, 50 + CaretLocator.maxCaretLikeWidth)

        let justOver = CaretLocator.caretAnchor(
            for: CGRect(x: 50, y: 0, width: CaretLocator.maxCaretLikeWidth + 1, height: 17))
        XCTAssertEqual(justOver.minX, 50)
    }

    func testTheAnchorAlwaysReportsAHairlineWidth() {
        for width in [CGFloat(0), 8, 427] {
            let anchored = CaretLocator.caretAnchor(
                for: CGRect(x: 10, y: 10, width: width, height: 17))
            XCTAssertEqual(anchored.width, 1, "width \(width)")
        }
    }
}
