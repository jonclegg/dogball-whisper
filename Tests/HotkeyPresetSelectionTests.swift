import XCTest
@testable import DogballWhisper

/// The invariant this pins is the one a review already caught once: picking
/// "Custom" in the hotkey list must never commit the placeholder combo the
/// row is tagged with. Two screens now share that picker, so getting it wrong
/// silently rebinds dictation to ⌃Space in both.
final class HotkeyPresetSelectionTests: XCTestCase {
    func testChoosingCustomDoesNotChangeTheLiveBinding() {
        var selection = HotkeyPresetSelection(binding: .rightOption)
        selection.select(selection.customTag)

        XCTAssertEqual(selection.binding, .rightOption)
        XCTAssertNotEqual(selection.binding, HotkeyPresetSelection.placeholderCustomBinding)
        XCTAssertTrue(selection.isChoosingCustom)
    }

    func testChoosingCustomShowsCustomAsSelectedWhileTheOldBindingStaysInEffect() {
        var selection = HotkeyPresetSelection(binding: .fn)
        selection.select(selection.customTag)

        XCTAssertEqual(selection.displayed, HotkeyPresetSelection.placeholderCustomBinding)
        XCTAssertEqual(selection.binding, .fn)
    }

    func testRecordingARealComboIsWhatFinallyCommitsIt() {
        var selection = HotkeyPresetSelection(binding: .rightOption)
        selection.select(selection.customTag)

        let recorded = HotkeyBinding(comboKeyCode: 2, modifiers: [.maskControl, .maskShift])
        selection.commit(recorded)

        XCTAssertEqual(selection.binding, recorded)
        XCTAssertFalse(selection.isChoosingCustom)
        XCTAssertEqual(selection.displayed, recorded)
    }

    func testPickingAPresetCommitsItImmediately() {
        var selection = HotkeyPresetSelection(binding: .rightOption)
        selection.select(.rightCommand)

        XCTAssertEqual(selection.binding, .rightCommand)
        XCTAssertFalse(selection.isChoosingCustom)
    }

    func testPickingAPresetAfterChoosingCustomLeavesRecordingMode() {
        var selection = HotkeyPresetSelection(binding: .rightOption)
        selection.select(selection.customTag)
        selection.select(.fn)

        XCTAssertEqual(selection.binding, .fn)
        XCTAssertFalse(selection.isChoosingCustom)
    }

    // With a combo already bound, the "Custom" row is tagged with that combo
    // rather than the placeholder, so re-picking it must leave it alone
    // instead of resetting the user's binding to ⌃Space.
    func testReselectingCustomWithAComboAlreadyBoundKeepsThatCombo() {
        let combo = HotkeyBinding(comboKeyCode: 2, modifiers: [.maskControl, .maskShift])
        var selection = HotkeyPresetSelection(binding: combo)
        XCTAssertEqual(selection.customTag, combo)

        selection.select(selection.customTag)

        XCTAssertEqual(selection.binding, combo)
        XCTAssertFalse(selection.isChoosingCustom)
    }
}
