import Foundation

/// The state behind the hotkey picker's preset list, and the one rule that
/// makes it safe: choosing "Custom" must never itself rebind the app.
///
/// The picker needs a `HotkeyBinding` to tag the "Custom" row with, because
/// that is what a SwiftUI `Picker` selects over. There is no binding to use
/// when the user has not recorded one yet, so the row carries a placeholder
/// (Control+Space). Committing that placeholder would silently rebind
/// dictation to ⌃Space the instant someone opened the list — which is exactly
/// what an earlier version did, and what this type exists to make impossible
/// to reintroduce in either of the two screens that now share the picker.
///
/// Pure and free of SwiftUI so the rule can be tested directly rather than
/// through a view.
struct HotkeyPresetSelection: Equatable {
    /// The binding actually in effect. Only a recorded combo or a chosen
    /// preset ever changes this.
    var binding: HotkeyBinding
    /// True once "Custom" has been picked but no combo has been recorded yet:
    /// the recorder is shown, and the list displays "Custom" as selected,
    /// while `binding` stays exactly as it was.
    var isChoosingCustom: Bool

    init(binding: HotkeyBinding, isChoosingCustom: Bool = false) {
        self.binding = binding
        self.isChoosingCustom = isChoosingCustom
    }

    /// The placeholder combo the "Custom" row is tagged with when there is no
    /// custom binding to tag it with. Never becomes the live hotkey.
    static let placeholderCustomBinding = HotkeyBinding(
        comboKeyCode: 49, modifiers: [.maskControl])

    /// What the "Custom" row is tagged with right now: an existing custom
    /// combo if there is one, so picking it does not disturb it, otherwise
    /// the placeholder.
    var customTag: HotkeyBinding {
        binding.kind == .combo ? binding : Self.placeholderCustomBinding
    }

    /// What the picker shows as selected.
    var displayed: HotkeyBinding {
        isChoosingCustom ? customTag : binding
    }

    /// Apply a row the user picked.
    ///
    /// Picking a preset commits it. Picking "Custom" while the current
    /// binding is not already a combo is cosmetic only — it reveals the
    /// recorder and leaves `binding` alone, so the previous hotkey stays in
    /// effect until a real keypress is recorded.
    mutating func select(_ selected: HotkeyBinding) {
        if selected == customTag, binding.kind != .combo {
            isChoosingCustom = true
        } else {
            isChoosingCustom = false
            binding = selected
        }
    }

    /// A combo arriving from the recorder, or a binding loaded from
    /// preferences: either way there is nothing left to choose.
    mutating func commit(_ recorded: HotkeyBinding) {
        binding = recorded
        isChoosingCustom = false
    }
}
