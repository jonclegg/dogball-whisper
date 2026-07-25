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
            return "Notices when you hold the dictation key, in any app."
        case .accessibility:
            return "Finds your text cursor and pastes the finished text. Without it, text is copied to the clipboard instead, and the waveform panel sits in a fixed position instead of following your cursor."
        }
    }

    /// Accessibility is optional: the app degrades to clipboard-only insertion.
    var isRequired: Bool {
        self != .accessibility
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

    static var allRequiredGranted: Bool {
        PermissionKind.allCases.filter(\.isRequired).allSatisfy(isGranted)
    }

    /// Only microphone and accessibility can be prompted for. Input Monitoring
    /// has no request API that returns a result, so its row deep-links to
    /// System Settings and the UI polls until it flips.
    static func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            _ = await AudioRecorder.requestPermission()
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
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
