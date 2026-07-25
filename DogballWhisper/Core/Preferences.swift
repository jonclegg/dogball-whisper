import Foundation

enum InsertionMode: String, Codable {
    case paste
    case clipboardOnly
}

/// Typed wrapper over UserDefaults. Everything the user can configure except
/// the OpenRouter key, which lives in the Keychain.
final class Preferences {
    private enum Key {
        static let hotkeyBinding = "hotkeyBinding"
        static let activeModelID = "activeModelID"
        static let cleanupEnabled = "cleanupEnabled"
        static let cleanupModelID = "cleanupModelID"
        static let cleanupPrompt = "cleanupPrompt"
        static let insertionMode = "insertionMode"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    static let defaultCleanupModelID = "anthropic/claude-haiku-4.5"

    static let defaultCleanupPrompt = """
        Clean up this dictated text. Remove filler words (um, uh, like, you know), \
        false starts, stutters, and repeated words. Fix punctuation and capitalization.

        The speaker is a software developer, and speech recognition regularly \
        mishears technical vocabulary as ordinary English. When a word only makes \
        sense as a mistranscription, replace it with the term a developer plainly \
        meant. For example "merge it to Maine" is "merge it to main", "guess pull" \
        is "git pull", "pull request" may arrive as "pole request", and repo, \
        commit, branch, rebase, async, API, JSON, Swift, and macOS are frequently \
        garbled. Only make the substitution when the developer reading is clearly \
        the intended one, and leave the word alone when it is genuinely ambiguous.

        Otherwise do not rephrase, reorder, summarize, or add anything. Keep the \
        speaker's exact wording and voice. Return only the cleaned text.
        """

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.cleanupEnabled: true,
            Key.cleanupModelID: Self.defaultCleanupModelID,
            Key.insertionMode: InsertionMode.paste.rawValue,
        ])
    }

    var activeModelID: String? {
        get { defaults.string(forKey: Key.activeModelID) }
        set { defaults.set(newValue, forKey: Key.activeModelID) }
    }

    var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.cleanupEnabled) }
        set { defaults.set(newValue, forKey: Key.cleanupEnabled) }
    }

    var cleanupModelID: String {
        get { nonBlank(Key.cleanupModelID, default: Self.defaultCleanupModelID) }
        set { defaults.set(newValue, forKey: Key.cleanupModelID) }
    }

    /// Blank prompts would silently turn cleanup into a passthrough, so an
    /// empty value reads back as the default instead.
    var cleanupPrompt: String {
        get { nonBlank(Key.cleanupPrompt, default: Self.defaultCleanupPrompt) }
        set { defaults.set(newValue, forKey: Key.cleanupPrompt) }
    }

    var insertionMode: InsertionMode {
        get { InsertionMode(rawValue: defaults.string(forKey: Key.insertionMode) ?? "") ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: Key.insertionMode) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    /// Raw storage for the hotkey binding; Task 3 encodes/decodes it.
    var hotkeyBindingData: Data? {
        get { defaults.data(forKey: Key.hotkeyBinding) }
        set { defaults.set(newValue, forKey: Key.hotkeyBinding) }
    }

    var hotkeyBinding: HotkeyBinding {
        get {
            guard let data = hotkeyBindingData,
                  let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data)
            else { return .rightOption }
            return binding
        }
        set { hotkeyBindingData = try? JSONEncoder().encode(newValue) }
    }

    /// Blank values would silently turn cleanup into a passthrough, so an
    /// empty or whitespace-only stored value reads back as the default.
    private func nonBlank(_ key: String, default fallback: String) -> String {
        let stored = defaults.string(forKey: key) ?? ""
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : stored
    }
}
