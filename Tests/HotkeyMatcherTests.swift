import XCTest
import CoreGraphics
@testable import DogballWhisper

final class HotkeyMatcherTests: XCTestCase {

    // Right option pressed alone starts a dictation; releasing it ends one.
    func testModifierOnlyBindingBeginsAndEnds() {
        var matcher = HotkeyMatcher(binding: .rightOption)

        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 61, flags: [.maskAlternate])), .began)
        XCTAssertTrue(matcher.isEngaged)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 61, flags: [])), .ended)
        XCTAssertFalse(matcher.isEngaged)
    }

    // The left option key must not trigger a binding on the right one.
    func testOppositeSideKeyIsIgnored() {
        var matcher = HotkeyMatcher(binding: .rightOption)
        XCTAssertNil(matcher.handle(.flagsChanged(keyCode: 58, flags: [.maskAlternate])))
        XCTAssertFalse(matcher.isEngaged)
    }

    // Holding shift and then pressing right option is a different gesture;
    // starting there would hijack real shortcuts.
    func testDoesNotBeginWhenAnotherModifierIsAlreadyHeld() {
        var matcher = HotkeyMatcher(binding: .rightOption)
        XCTAssertNil(matcher.handle(.flagsChanged(keyCode: 61, flags: [.maskAlternate, .maskShift])))
        XCTAssertFalse(matcher.isEngaged)
    }

    // This is what keeps option-e (accents) and option-click shortcuts working:
    // any real key pressed while the hotkey is held abandons the dictation.
    func testKeyPressedWhileEngagedCancels() {
        var matcher = HotkeyMatcher(binding: .rightOption)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 61, flags: [.maskAlternate])), .began)
        XCTAssertEqual(matcher.handle(.keyDown(keyCode: 14, flags: [.maskAlternate])), .cancelled)
        XCTAssertFalse(matcher.isEngaged)
        // The later release must not be reported as a normal end.
        XCTAssertNil(matcher.handle(.flagsChanged(keyCode: 61, flags: [])))
    }

    func testAnotherModifierPressedWhileEngagedCancels() {
        var matcher = HotkeyMatcher(binding: .rightOption)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 61, flags: [.maskAlternate])), .began)
        XCTAssertEqual(
            matcher.handle(.flagsChanged(keyCode: 56, flags: [.maskAlternate, .maskShift])),
            .cancelled
        )
    }

    // Bits like non-coalesced and caps lock ride along on real events and
    // must not read as "another modifier is down".
    func testIrrelevantFlagBitsAreIgnored() {
        var matcher = HotkeyMatcher(binding: .rightOption)
        let noisy: CGEventFlags = [.maskAlternate, .maskNonCoalesced, .maskAlphaShift]
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 61, flags: noisy)), .began)
    }

    func testFnBindingUsesTheSecondaryFnMask() {
        var matcher = HotkeyMatcher(binding: .fn)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 63, flags: [.maskSecondaryFn])), .began)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 63, flags: [])), .ended)
    }

    // A custom combo begins on key down and ends when the key or its
    // modifiers are released.
    func testComboBindingBeginsOnKeyDownAndEndsOnRelease() {
        var matcher = HotkeyMatcher(
            binding: HotkeyBinding(comboKeyCode: 49, modifiers: [.maskAlternate])
        )
        XCTAssertEqual(matcher.handle(.keyDown(keyCode: 49, flags: [.maskAlternate])), .began)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 58, flags: [])), .ended)
    }

    // Combos must be swallowed or the app would also receive the keystroke.
    // Modifier-only bindings must never be swallowed.
    func testOnlyComboEventsAreConsumed() {
        let combo = HotkeyMatcher(binding: HotkeyBinding(comboKeyCode: 49, modifiers: [.maskAlternate]))
        XCTAssertTrue(combo.consumesEvent(.keyDown(keyCode: 49, flags: [.maskAlternate])))
        XCTAssertFalse(combo.consumesEvent(.keyDown(keyCode: 14, flags: [.maskAlternate])))

        let modifierOnly = HotkeyMatcher(binding: .rightOption)
        XCTAssertFalse(modifierOnly.consumesEvent(.flagsChanged(keyCode: 61, flags: [.maskAlternate])))
    }

    func testDisplayNames() {
        XCTAssertEqual(HotkeyBinding.rightOption.displayName, "Right ⌥")
        XCTAssertEqual(HotkeyBinding.rightCommand.displayName, "Right ⌘")
        XCTAssertEqual(HotkeyBinding.fn.displayName, "fn")
        XCTAssertEqual(
            HotkeyBinding(comboKeyCode: 49, modifiers: [.maskAlternate]).displayName,
            "⌥Space"
        )
    }

    func testBindingSurvivesEncodingRoundTrip() throws {
        let binding = HotkeyBinding(comboKeyCode: 49, modifiers: [.maskAlternate, .maskControl])
        let data = try JSONEncoder().encode(binding)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyBinding.self, from: data), binding)
    }
}
