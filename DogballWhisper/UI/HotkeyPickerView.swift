import SwiftUI

/// The hold-to-talk key picker: right ⌥ / right ⌘ / fn / a custom recorded
/// combo, plus the fn-conflict warning. Shared between Settings > General
/// and onboarding's hotkey step so the "Custom" selection logic below (see
/// `presetSelection`) — which was fixed once already after a review found it
/// would silently bind the placeholder combo — exists in exactly one place.
///
/// Owns its own copy of the binding (seeded from `preferences.hotkeyBinding`
/// on appear) and writes every change straight back through `preferences`
/// and `onHotkeyChange`, so either call site gets persistence and a live
/// `HotkeyMonitor` update for free.
struct HotkeyPickerView: View {
    let preferences: Preferences
    let onHotkeyChange: (HotkeyBinding) -> Void

    @State private var binding: HotkeyBinding = .rightOption
    @State private var fnWarning: String?
    // True once the user has picked the "Custom" row but has not yet
    // recorded a combo. Drives the Picker's displayed selection and reveals
    // the recorder without ever writing into `binding` — the placeholder
    // Control+Space tag behind "Custom" must never itself become the live
    // hotkey. See `presetSelection` for why.
    @State private var isChoosingCustom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Key", selection: presetSelection) {
                Text("Right ⌥").tag(HotkeyBinding.rightOption)
                Text("Right ⌘").tag(HotkeyBinding.rightCommand)
                Text("fn / 🌐").tag(HotkeyBinding.fn)
                Text("Custom").tag(customTag)
            }
            if binding.kind == .combo || isChoosingCustom {
                ShortcutRecorderView(binding: $binding)
            }
            if let fnWarning {
                Text(fnWarning).font(.callout).foregroundStyle(.orange)
                Button("Open keyboard settings") {
                    Permissions.openKeyboardSettings()
                }
            }
        }
        .onAppear {
            binding = preferences.hotkeyBinding
            isChoosingCustom = false
            refreshFnWarning()
        }
        .onChange(of: binding) { _, new in
            isChoosingCustom = false
            preferences.hotkeyBinding = new
            onHotkeyChange(new)
            refreshFnWarning()
        }
    }

    /// Sentinel for the "Custom" row, so picking it switches the UI into
    /// recording mode without clobbering an existing custom binding.
    private var customTag: HotkeyBinding {
        binding.kind == .combo ? binding : HotkeyBinding(comboKeyCode: 49, modifiers: [.maskControl])
    }

    /// Selecting a preset row commits it straight to `binding`, which
    /// persists and pushes it to the live monitor. Selecting "Custom" is
    /// cosmetic only: its tag is a placeholder (Control+Space) that must
    /// never itself become the active hotkey, so this just flips
    /// `isChoosingCustom` to reveal the recorder. `binding` — and therefore
    /// the persisted preference and the live monitor — only change once
    /// `ShortcutRecorderView` captures a real keypress and writes through
    /// `$binding` directly. Until then the previous binding stays in effect.
    private var presetSelection: Binding<HotkeyBinding> {
        Binding(
            get: { isChoosingCustom ? customTag : binding },
            set: { newValue in
                if newValue == customTag, binding.kind != .combo {
                    isChoosingCustom = true
                } else {
                    isChoosingCustom = false
                    binding = newValue
                }
            }
        )
    }

    /// macOS claims fn for emoji, input switching, or its own dictation unless
    /// "Press 🌐 to" is set to Do Nothing.
    private func refreshFnWarning() {
        guard binding == .fn else {
            fnWarning = nil
            return
        }
        fnWarning = Permissions.fnKeyIsClaimedBySystem
            ? "macOS currently uses fn for something else. Set Keyboard > Press 🌐 to > Do Nothing."
            : nil
    }
}
