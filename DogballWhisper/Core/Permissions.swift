import AVFoundation
import AppKit
import ApplicationServices

enum PermissionKind: String, CaseIterable {
    case microphone
    case inputMonitoring
    case accessibility

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    var explanation: String {
        switch self {
        case .microphone:
            return "Records your voice while you hold the dictation key. Audio stays on this Mac."
        case .inputMonitoring:
            return "Usually not needed. Grant this only if the dictation key does nothing after you have allowed Accessibility."
        case .accessibility:
            return "Notices when you hold the dictation key in any app, finds your text cursor, and pastes the finished text."
        }
    }

    /// Accessibility is what actually powers the app: a keyboard `CGEventTap`
    /// runs on it, and so does pasting. Input Monitoring is not needed for a
    /// session event tap, and macOS will not even list an app there until it
    /// installs a tap — so requiring it deadlocked setup on a clean machine.
    var isRequired: Bool {
        self != .inputMonitoring
    }
}

enum Permissions {
    static func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    /// Creates an event tap and immediately throws it away. The tap is never
    /// added to a run loop and never sees an event — the point is the attempt,
    /// which is what makes macOS list this app under Input Monitoring so the
    /// user has something to grant.
    private static func registerForInputMonitoringByProbingTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else { return }
        CFMachPortInvalidate(tap)
    }

    static var allRequiredGranted: Bool {
        PermissionKind.allCases.filter(\.isRequired).allSatisfy(isGranted)
    }

    /// Only microphone and accessibility can be prompted for. Input Monitoring
    /// has no request API that returns a result, so its row deep-links to
    /// System Settings and the UI polls until it flips.
    ///
    /// `@MainActor` is load-bearing, not decoration. `CGRequestListenEventAccess`
    /// and the AX prompt both register the app with TCC and present system UI,
    /// and they silently do nothing when called off the main thread. Without
    /// this, the app never appeared in System Settings > Input Monitoring at
    /// all, because a nonisolated `async` func hops off the main actor.
    @MainActor
    static func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            _ = await AudioRecorder.requestPermission()
        case .inputMonitoring:
            // Asking politely is not enough. macOS only adds an app to
            // System Settings > Privacy & Security > Input Monitoring once the
            // app actually attempts to install an event tap —
            // CGRequestListenEventAccess on its own leaves it absent from the
            // list entirely, so there is no toggle for the user to flip. That
            // deadlocks setup, because startMonitoring is gated on a permission
            // that can never be granted. Attempting a throwaway tap is what
            // registers us; other dictation apps rely on the same mechanism.
            _ = CGRequestListenEventAccess()
            if !CGPreflightListenEventAccess() {
                registerForInputMonitoringByProbingTap()
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    }

    static func settingsURL(for kind: PermissionKind) -> URL {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(settingsURL(for: kind))
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    static func summary(granted: Set<PermissionKind>) -> String {
        let missing = PermissionKind.allCases
            .filter { $0.isRequired && !granted.contains($0) }
            .map(\.title)
        guard !missing.isEmpty else { return "Ready" }
        return missing.joined(separator: " and ") + " needed"
    }

    /// System Settings > Keyboard > "Press 🌐 to". Anything but 0 (Do Nothing)
    /// means macOS consumes the fn key before we see it.
    static func fnUsageIsClaimed(_ value: Int) -> Bool {
        value != 0
    }

    static var fnKeyIsClaimedBySystem: Bool {
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?
            .integer(forKey: "AppleFnUsageType") ?? 0
        return fnUsageIsClaimed(value)
    }
}
