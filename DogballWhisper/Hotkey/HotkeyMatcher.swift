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

    /// Switches to a new binding, e.g. because the user changed it in
    /// settings mid-hold. If a dictation was already in flight under the old
    /// binding, it can never be paired with a matching release once the
    /// binding changes underneath it, so this reports it as cancelled before
    /// applying the new binding.
    mutating func rebind(to newBinding: HotkeyBinding) -> HotkeySignal? {
        let signal: HotkeySignal? = isEngaged ? .cancelled : nil
        isEngaged = false
        binding = newBinding
        return signal
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
            if isEngaged {
                // The held key repeats via keyDown; ignore those. Any other
                // key means the user is typing something else and abandons
                // the dictation, same rule as modifier-only bindings.
                guard keyCode != binding.keyCode else { return nil }
                isEngaged = false
                return .cancelled
            }
            // A bare key with no modifiers is not a usable global hotkey:
            // "!contains(modifiers)" below would never be true for an empty
            // set, so such a combo could engage but never end.
            guard !binding.modifiers.isEmpty,
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
