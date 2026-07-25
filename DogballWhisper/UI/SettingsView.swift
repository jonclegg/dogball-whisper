import AppKit
import Combine
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

    @State private var insertionMode: InsertionMode = .paste
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Hold to talk") {
                HotkeyPickerView(preferences: preferences, onHotkeyChange: onHotkeyChange)
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
            insertionMode = preferences.insertionMode
            launchAtLogin = LoginItem.isEnabled
        }
        .onChange(of: insertionMode) { _, new in preferences.insertionMode = new }
        .onChange(of: launchAtLogin) { _, new in
            LoginItem.setEnabled(new)
            onLaunchAtLoginChange()
        }
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
    /// What the Keychain holds, as of the last time this tab read or wrote
    /// it. `apiKey` is compared against this rather than written blindly, for
    /// the same reason the other three fields compare against `preferences`:
    /// `onAppear` seeding the field is itself a change and would otherwise
    /// fire the handler.
    @State private var storedAPIKey = ""
    /// The debounced write. Typing a 73-character key would otherwise be 73
    /// Keychain delete-plus-adds, so the write waits for a pause; closing the
    /// window or pressing return flushes it early.
    @State private var apiKeyCommit: Task<Void, Never>?

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
                HStack {
                    Button("Reset to default") { prompt = Preferences.defaultCleanupPrompt }
                    Button("Use the developer prompt") {
                        prompt = Preferences.developerCleanupPrompt
                    }
                }
                Text("The developer prompt also fixes technical terms the speech model mishears, so \"Maine\" becomes \"main\" and \"guess\" becomes \"git\". Pick it only if you dictate about code, because it rewrites those words wherever they appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            storedAPIKey = KeychainStore.read() ?? ""
            apiKey = storedAPIKey
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
        // Emptying the field revokes the key. It is the only way to stop
        // sending dictated text to a third party from inside the app, so it
        // has to be a deletion rather than a save the Keychain layer ignores.
        .onChange(of: apiKey) { _, _ in
            apiKeyCommit?.cancel()
            apiKeyCommit = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                commitAPIKey()
            }
        }
        .onSubmit { commitAPIKey() }
        // The settings window keeps this view alive when it closes, so
        // `onDisappear` never runs (the same behavior `OnboardingWindowController`
        // documents). Without this, a key pasted and then immediately ⌘W'd
        // away would be lost inside the debounce window.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            commitAPIKey()
        }
        // AppKit does not post willCloseNotification on terminate, so quitting
        // with the settings window still open would drop whatever is sitting
        // in the debounce. That fails in the worse direction for a *cleared*
        // field: the user believes they revoked the key and did not.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            commitAPIKey()
        }
    }

    private func commitAPIKey() {
        apiKeyCommit?.cancel()
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != storedAPIKey else { return }
        // Only treat the field as committed if the keychain actually took it.
        // Recording it optimistically would make every later flush a no-op via
        // the guard above, so a failed revocation would leave the user
        // believing the key is gone while it is still stored and still used.
        guard KeychainStore.setKey(fromField: trimmed) else {
            Diagnostics.log("keychain: failed to store the API key change")
            return
        }
        storedAPIKey = trimmed
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
                // `PolishError` describes itself by status and cause, never
                // by the provider's response body: providers echo submitted
                // text back in moderation rejections, and this string is put
                // on screen and can be copied out of it.
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}
