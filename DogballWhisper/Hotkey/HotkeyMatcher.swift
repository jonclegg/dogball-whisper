import CoreGraphics

enum HotkeyInput: Equatable {
    case flagsChanged(keyCode: UInt16, flags: CGEventFlags)
    case keyDown(keyCode: UInt16, flags: CGEventFlags)
}

enum HotkeySignal: Equatable {
    case began
    case ended
    case cancelled
}

/// Pure state machine translating keyboard events into dictation signals.
/// No CoreGraphics tap involved, so every rule above is unit-testable.
struct HotkeyMatcher {
    /// The only flags that matter. Caps lock, numeric pad, help, and the
    /// non-coalesced bit ride along on real events and must be ignored.
    static let relevantMasks: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn,
    ]

    var binding: HotkeyBinding
    private(set) var isEngaged = false

    init(binding: HotkeyBinding) {
        self.binding = binding
    }

    mutating func handle(_ input: HotkeyInput) -> HotkeySignal? {
        binding.isModifierOnly ? handleModifierOnly(input) : handleCombo(input)
    }

    /// Combo bindings must be swallowed by the tap so the focused app never
    /// receives the keystroke. Modifier-only bindings are always passed
    /// through, since swallowing them would break the modifier itself.
    func consumesEvent(_ input: HotkeyInput) -> Bool {
        guard !binding.isModifierOnly else { return false }
        guard case let .keyDown(keyCode, flags) = input else { return false }
        return keyCode == binding.keyCode && Self.filtered(flags) == binding.modifiers
    }

    private static func filtered(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(relevantMasks)
    }

    private mutating func handleModifierOnly(_ input: HotkeyInput) -> HotkeySignal? {
        guard let targetMask = ModifierKeyCode.mask(for: binding.keyCode) else { return nil }

        switch input {
        case let .keyDown(_, _):
            // Any real key while held means the user is typing a shortcut.
            guard isEngaged else { return nil }
            isEngaged = false
            return .cancelled

        case let .flagsChanged(keyCode, rawFlags):
            let flags = Self.filtered(rawFlags)
            let others = flags.subtracting(targetMask)

            if keyCode == binding.keyCode {
                if flags.contains(targetMask) {
                    guard !isEngaged, others.isEmpty else { return nil }
                    isEngaged = true
                    return .began
                } else {
                    guard isEngaged else { return nil }
                    isEngaged = false
                    return .ended
                }
            }

            // A different modifier changed while we were engaged.
            guard isEngaged, !others.isEmpty else { return nil }
            isEngaged = false
            return .cancelled
        }
    }

    private mutating func handleCombo(_ input: HotkeyInput) -> HotkeySignal? {
        switch input {
        case let .keyDown(keyCode, rawFlags):
            guard !isEngaged,
                  keyCode == binding.keyCode,
                  Self.filtered(rawFlags) == binding.modifiers
            else { return nil }
            isEngaged = true
            return .began

        case let .flagsChanged(_, rawFlags):
            // Releasing any of the combo's modifiers ends the dictation.
            guard isEngaged, !Self.filtered(rawFlags).contains(binding.modifiers) else { return nil }
            isEngaged = false
            return .ended
        }
    }
}
