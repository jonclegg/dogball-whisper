import SwiftUI

struct SettingsView: View {
    let preferences: Preferences
    let models: ModelManager
    let onHotkeyChange: (HotkeyBinding) -> Void
    let onLaunchAtLoginChange: () -> Void

    var body: some View {
        TabView {
            GeneralSettingsTab(
                preferences: preferences, onHotkeyChange: onHotkeyChange,
                onLaunchAtLoginChange: onLaunchAtLoginChange)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelsSettingsTab(models: models)
                .tabItem { Label("Models", systemImage: "square.and.arrow.down") }
            CleanupSettingsTab(preferences: preferences)
                .tabItem { Label("Cleanup", systemImage: "wand.and.sparkles") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettingsTab: View {
    let preferences: Preferences
    let onHotkeyChange: (HotkeyBinding) -> Void
    let onLaunchAtLoginChange: () -> Void

    @State private var binding: HotkeyBinding = .rightOption
    @State private var insertionMode: InsertionMode = .paste
    @State private var launchAtLogin = false
    @State private var fnWarning: String?
    // True once the user has picked the "Custom" row but has not yet
    // recorded a combo. Drives the Picker's displayed selection and reveals
    // the recorder without ever writing into `binding` — the placeholder
    // Control+Space tag behind "Custom" must never itself become the live
    // hotkey. See `presetSelection` for why.
    @State private var isChoosingCustom = false

    var body: some View {
        Form {
            Section("Hold to talk") {
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
            Section("Insertion") {
                Picker("When dictation finishes", selection: $insertionMode) {
                    Text("Paste into the focused app").tag(InsertionMode.paste)
                    Text("Copy to the clipboard only").tag(InsertionMode.clipboardOnly)
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            binding = preferences.hotkeyBinding
            insertionMode = preferences.insertionMode
            launchAtLogin = LoginItem.isEnabled
            isChoosingCustom = false
            refreshFnWarning()
        }
        .onChange(of: binding) { _, new in
            isChoosingCustom = false
            preferences.hotkeyBinding = new
            onHotkeyChange(new)
            refreshFnWarning()
        }
        .onChange(of: insertionMode) { _, new in preferences.insertionMode = new }
        .onChange(of: launchAtLogin) { _, new in
            LoginItem.setEnabled(new)
            onLaunchAtLoginChange()
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

private struct ModelsSettingsTab: View {
    let models: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(ModelCatalog.all) { descriptor in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.name).font(.body)
                        Text("\(descriptor.detail) · \(descriptor.sizeLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    controls(for: descriptor)
                }
                .padding(.vertical, 4)
            }
            if let error = models.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).padding(12)
            }
        }
    }

    /// Every control is gated on `models.isBusy`, which covers activation as
    /// well as downloading: loading a large model takes seconds, and an
    /// enabled "Use" or "Delete" during that window would start a second
    /// activation or pull files out from under the one already running.
    @ViewBuilder
    private func controls(for descriptor: ModelDescriptor) -> some View {
        switch models.state(for: descriptor) {
        case .notInstalled:
            Button("Install") { Task { try? await models.install(descriptor) } }
                .disabled(models.isBusy)
        case let .downloading(fraction):
            ProgressView(value: fraction).frame(width: 90)
        case .installed:
            if models.activatingModelID == descriptor.id {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button("Use") { Task { try? await models.makeActive(descriptor) } }
                        .disabled(models.isBusy)
                    Button("Delete") { try? models.delete(descriptor) }
                        .disabled(models.isBusy)
                }
            }
        case .active:
            HStack(spacing: 8) {
                Text("Active").foregroundStyle(.secondary)
                Button("Delete") { try? models.delete(descriptor) }
                    .disabled(models.isBusy)
            }
        }
    }
}

private struct CleanupSettingsTab: View {
    let preferences: Preferences

    @State private var enabled = true
    @State private var apiKey = ""
    @State private var modelID = ""
    @State private var prompt = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Toggle("Clean up transcripts", isOn: $enabled)
                Text("Only the transcribed text is sent to OpenRouter. Audio never leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("OpenRouter") {
                SecureField("API key", text: $apiKey)
                TextField("Model", text: $modelID)
                Text("Suggestions: anthropic/claude-haiku-4.5, google/gemini-3.5-flash, z-ai/glm-5-turbo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Prompt") {
                TextEditor(text: $prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 110)
                Button("Reset to default") { prompt = Preferences.defaultCleanupPrompt }
            }
            Section {
                HStack {
                    Button("Test") { runTest() }.disabled(isTesting)
                    if let testResult {
                        Text(testResult).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            enabled = preferences.cleanupEnabled
            modelID = preferences.cleanupModelID
            prompt = preferences.cleanupPrompt
            apiKey = KeychainStore.read() ?? ""
        }
        .onChange(of: enabled) { _, new in preferences.cleanupEnabled = new }
        .onChange(of: modelID) { _, new in preferences.cleanupModelID = new }
        .onChange(of: prompt) { _, new in preferences.cleanupPrompt = new }
        .onChange(of: apiKey) { _, new in KeychainStore.save(new) }
    }

    private func runTest() {
        isTesting = true
        testResult = "Testing…"
        let sample = "so um I was thinking that we could uh maybe ship it on friday"
        Task {
            do {
                let cleaned = try await PolishService().clean(
                    sample, prompt: prompt, model: modelID)
                testResult = cleaned
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}
