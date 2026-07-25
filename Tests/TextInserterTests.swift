import XCTest
@testable import DogballWhisper

/// Covers only the pure decision extracted from `PasteboardTextInserter`:
/// whether a delayed restore should still apply. `insert()` itself posts real
/// keyboard events into whatever app has focus and touches the user's real
/// clipboard, so it is intentionally not called from a test.
final class TextInserterTests: XCTestCase {
    func testRestoreAppliesWhenNothingElseTouchedThePasteboard() {
        XCTAssertTrue(
            PasteboardTextInserter.shouldRestore(currentChangeCount: 42, expectedChangeCount: 42)
        )
    }

    func testRestoreIsSkippedWhenTheChangeCountAdvanced() {
        // A later change count means something else -- a Cmd-C, or a second
        // dictation's own write -- now owns the pasteboard.
        XCTAssertFalse(
            PasteboardTextInserter.shouldRestore(currentChangeCount: 43, expectedChangeCount: 42)
        )
    }
}
