import AppKit
import SwiftUI

/// Hosts the setup window. The window is a gate, not a nag: the app cannot
/// dictate anything until the required permissions and a model exist, so
/// `onFinished` only fires from "Start dictating" once both are true.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let preferences: Preferences
    private let models: ModelManager
    private let onHotkeyChange: (HotkeyBinding) -> Void
    private let onFinished: () -> Void
    private let poller = OnboardingPermissionPoller()

    init(
        preferences: Preferences, models: ModelManager,
        onHotkeyChange: @escaping (HotkeyBinding) -> Void, onFinished: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.models = models
        self.onHotkeyChange = onHotkeyChange
        self.onFinished = onFinished
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 520, height: 700),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Set up Dogball Whisper"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    preferences: preferences,
                    models: models,
                    poller: poller,
                    onHotkeyChange: onHotkeyChange,
                    onFinished: { [weak self] in
                        self?.onFinished()
                        self?.window?.close()
                    }
                )
            )
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        poller.start()
    }

    /// Fires whenever the window closes, whether from "Start dictating" or
    /// the titlebar's close button. `window.close()` only orders the window
    /// out (isReleasedWhenClosed is false so the window and its hosted
    /// SwiftUI view stay alive), and SwiftUI's onDisappear does not fire in
    /// that case — verified empirically: a bare `.onDisappear` on content
    /// hosted this way never runs after `.close()`, which would otherwise
    /// leak the 1-second poll timer for the rest of the process. Stopping it
    /// here, from a plain AppKit delegate callback that fires unconditionally
    /// on close, is the reliable backstop.
    func windowWillClose(_ notification: Notification) {
        poller.stop()
    }
}

/// Input Monitoring cannot report back whether it was granted, so this polls
/// permission state on a 1-second timer while the onboarding window is open.
/// Owned by the window controller (not the SwiftUI view) so it can be
/// stopped deterministically from `windowWillClose` — see the comment there.
@MainActor
@Observable
final class OnboardingPermissionPoller {
    private(set) var granted: Set<PermissionKind> = []
    private var timer: Timer?

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        granted = Set(PermissionKind.allCases.filter(Permissions.isGranted))
    }
}

struct OnboardingView: View {
    let preferences: Preferences
    let models: ModelManager
    let poller: OnboardingPermissionPoller
    let onHotkeyChange: (HotkeyBinding) -> Void
    let onFinished: () -> Void

    @State private var apiKey = ""
    /// Mirrors the hotkey the picker below currently holds, so the headline
    /// keeps naming the key the user actually has to hold. This window
    /// contains a hotkey picker, so a hardcoded "right ⌥" would be wrong the
    /// moment anyone used it.
    @State private var hotkeyName = HotkeyBinding.rightOption.displayName

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hold \(hotkeyName), talk, let go. The text lands wherever you were typing.")
                .font(.title3)

            VStack(spacing: 10) {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    permissionRow(kind)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Speech model").font(.headline)
                if let descriptor = ModelCatalog.descriptor(id: ModelCatalog.defaultModelID) {
                    HStack {
                        Text("\(descriptor.name) · \(descriptor.sizeLabel)")
                        Spacer()
                        switch models.state(for: descriptor) {
                        case .notInstalled:
                            Button("Download") { Task { try? await models.install(descriptor) } }
                                .disabled(models.isBusy)
                        case let .downloading(fraction):
                            ProgressView(value: fraction).frame(width: 120)
                        case .installed:
                            // Installed but not active is reachable (the
                            // automatic activation after a download can fail
                            // on its own, and preferences can be reset with
                            // the files still in place), and "Start dictating"
                            // needs an *active* model. Without a control here
                            // that state is a dead end: a checkmark above a
                            // permanently disabled button.
                            if models.activatingModelID == descriptor.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Use") { Task { try? await models.makeActive(descriptor) } }
                                    .disabled(models.isBusy)
                            }
                        case .active:
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    Text("More models are available in Settings once you are set up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = models.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Hotkey").font(.headline)
                Text("Hold this key to dictate, let go to paste. Change it now if your keyboard has no right ⌥. You can always come back to this in Settings later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HotkeyPickerView(preferences: preferences) { binding in
                    hotkeyName = binding.displayName
                    onHotkeyChange(binding)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Cleanup (optional)").font(.headline)
                SecureField("OpenRouter API key", text: $apiKey)
                Text("Removes ums and ahs and fixes punctuation. Only text is sent, never audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Text(Permissions.summary(granted: poller.granted))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start dictating") {
                    // Same rule as the settings tab: the field is prefilled
                    // from the Keychain, so leaving it empty is a decision to
                    // have no key rather than an accident.
                    KeychainStore.setKey(fromField: apiKey)
                    onFinished()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canFinish)
            }
        }
        .padding(20)
        .onAppear {
            poller.refresh()
            hotkeyName = preferences.hotkeyBinding.displayName
            // Show the key that is already stored, so running setup a second
            // time does not present an empty field that looks like there is
            // no key.
            apiKey = KeychainStore.read() ?? ""
        }
    }

    private var canFinish: Bool {
        Permissions.allRequiredGranted && models.activeModelID != nil
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: poller.granted.contains(kind)
                    ? "checkmark.circle.fill" : "circle.dashed"
            )
            .foregroundStyle(poller.granted.contains(kind) ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title + (kind.isRequired ? "" : " (optional)")).font(.body)
                Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !poller.granted.contains(kind) {
                Button("Grant") {
                    Task {
                        await Permissions.request(kind)
                        // macOS never re-prompts after a denial, so send the
                        // user straight to the pane when the prompt no-ops.
                        if !Permissions.isGranted(kind) {
                            Permissions.openSettings(for: kind)
                        }
                        poller.refresh()
                    }
                }
            }
        }
    }
}
