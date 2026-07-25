import XCTest
@testable import DogballWhisper

final class PasteboardSnapshotTests: XCTestCase {
    // A private pasteboard, so tests never touch the user's real clipboard.
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("com.jonclegg.DogballWhisper.tests"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    func testRestoringBringsBackTheOriginalText() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated", forType: .string)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")

        snapshot.restore(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestoringPreservesMultipleTypesOnOneItem() {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setString("<b>rich</b>", forType: .html)
        pasteboard.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated", forType: .string)
        snapshot.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "plain")
        XCTAssertEqual(pasteboard.string(forType: .html), "<b>rich</b>")
    }

    func testRestoringAnEmptyClipboardLeavesItEmpty() {
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.setString("dictated", forType: .string)
        snapshot.restore(to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }
}
