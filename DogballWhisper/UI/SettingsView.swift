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
    @State private var isCustomModel = false

    /// Fast, inexpensive models suited to a short rewrite. Not exhaustive on
    /// purpose — OpenRouter carries hundreds, and the custom field is there
    /// for anything not listed.
    /// Every model here was measured against this app's exact request shape:
    /// three transcript lengths, three runs each, reasoning disabled.
    ///
    ///     openai/gpt-4.1-nano         0.86s median, most faithful
    ///     amazon/nova-micro-v1        0.89s
    ///     openai/gpt-4.1              1.05s
    ///     anthropic/claude-haiku-4.5  1.24s
    ///     z-ai/glm-5-turbo            1.70s
    ///
    /// Both Gemini models are deliberately absent: their endpoints reject a
    /// disabled-reasoning request outright, and permitting reasoning puts them
    /// at the timeout. cohere/command-r7b is absent for quality, not speed —
    /// it rewrites rather than cleans ("Okay, I understand. We can merge the
    /// code to the 'main' branch...").
    private static let suggestedModels = [
        "openai/gpt-4.1-nano",
        "amazon/nova-micro-v1",
        "openai/gpt-4.1",
        "anthropic/claude-haiku-4.5",
        "z-ai/glm-5-turbo",
    ]

    /// Sentinel for the "Custom…" row. Contains a space, so it can never
    /// collide with a real OpenRouter model ID.
    private static let customModelTag = "custom model"

    /// Picking a listed model stores it directly; picking "Custom…" reveals
    /// the text field and leaves whatever is already stored in place, so
    /// choosing it does not blank out a working model ID.
    private var modelSelection: Binding<String> {
        Binding(
            get: { isCustomModel ? Self.customModelTag : modelID },
            set: { selected in
                if selected == Self.customModelTag {
                    isCustomModel = true
                } else {
                    isCustomModel = false
                    modelID = selected
                }
            }
        )
    }

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
                Picker("Model", selection: modelSelection) {
                    ForEach(Self.suggestedModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    Divider()
                    Text("Custom…").tag(Self.customModelTag)
                }
                if isCustomModel {
                    TextField("Model ID", text: $modelID)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Cleanup runs between letting go of the key and the text appearing, so a faster model means less waiting. Anything slower than \(Int(DictationCoordinator.Config().cleanupTimeout)) seconds is abandoned and the raw transcript is used.")
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
            // A stored model that is not on the list is by definition one the
            // user typed, so open on the custom field rather than silently
            // showing a different model as selected.
            isCustomModel = !Self.suggestedModels.contains(modelID)
            prompt = preferences.cleanupPrompt
            apiKey = KeychainStore.read() ?? ""
        }
        // Each of these writes only a genuine change. `onAppear` loads the
        // current values into `@State`, which is itself a change from the
        // empty initial value and therefore fires `onChange` — so writing
        // unconditionally persisted whatever the default happened to be the
        // first time the tab was ever opened, freezing that copy forever and
        // making later improvements to the default invisible.
        .onChange(of: enabled) { _, new in
            guard new != preferences.cleanupEnabled else { return }
            preferences.cleanupEnabled = new
        }
        .onChange(of: modelID) { _, new in
            guard new != preferences.cleanupModelID else { return }
            preferences.cleanupModelID = new
        }
        .onChange(of: prompt) { _, new in
            guard new != preferences.cleanupPrompt else { return }
            preferences.cleanupPrompt = new
        }
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
