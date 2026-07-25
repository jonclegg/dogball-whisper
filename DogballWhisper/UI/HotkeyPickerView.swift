import SwiftUI

/// The hold-to-talk key picker: right ⌥ / right ⌘ / fn / a custom recorded
/// combo, plus the fn-conflict warning. Shared between Settings > General
/// and onboarding's hotkey step, so the rule that picking "Custom" must not
/// commit its placeholder combo lives in exactly one place — and now in a
/// testable one: `HotkeyPresetSelection`, which this view only drives.
///
/// Owns its own copy of the binding (seeded from `preferences.hotkeyBinding`
/// on appear) and writes every change straight back through `preferences`
/// and `onHotkeyChange`, so either call site gets persistence and a live
/// `HotkeyMonitor` update for free.
struct HotkeyPickerView: View {
    let preferences: Preferences
    let onHotkeyChange: (HotkeyBinding) -> Void

    @State private var selection = HotkeyPresetSelection(binding: .rightOption)
    @State private var fnWarning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Key", selection: presetSelection) {
                Text("Right ⌥").tag(HotkeyBinding.rightOption)
                Text("Right ⌘").tag(HotkeyBinding.rightCommand)
                Text("fn / 🌐").tag(HotkeyBinding.fn)
                Text("Custom").tag(selection.customTag)
            }
            if selection.binding.kind == .combo || selection.isChoosingCustom {
                ShortcutRecorderView(binding: recordedBinding)
            }
            if let fnWarning {
                Text(fnWarning).font(.callout).foregroundStyle(.orange)
                Button("Open keyboard settings") {
                    Permissions.openKeyboardSettings()
                }
            }
        }
        .onAppear {
            selection = HotkeyPresetSelection(binding: preferences.hotkeyBinding)
            refreshFnWarning()
        }
        .onChange(of: selection.binding) { old, new in
            guard new != old else { return }
            preferences.hotkeyBinding = new
            onHotkeyChange(new)
            refreshFnWarning()
        }
    }

    /// The picker's selected row. Reading and writing both go through
    /// `HotkeyPresetSelection`, which is where the "Custom" rule is enforced
    /// and where it is tested.
    private var presetSelection: Binding<HotkeyBinding> {
        Binding(
            get: { selection.displayed },
            set: { selection.select($0) }
        )
    }

    /// What the recorder writes into: a real recorded keypress, which always
    /// commits.
    private var recordedBinding: Binding<HotkeyBinding> {
        Binding(
            get: { selection.binding },
            set: { selection.commit($0) }
        )
    }

    /// macOS claims fn for emoji, input switching, or its own dictation unless
    /// "Press 🌐 to" is set to Do Nothing.
    private func refreshFnWarning() {
        guard selection.binding == .fn else {
            fnWarning = nil
            return
        }
        fnWarning = Permissions.fnKeyIsClaimedBySystem
            ? "macOS currently uses fn for something else. Set Keyboard > Press 🌐 to > Do Nothing."
            : nil
    }
}
