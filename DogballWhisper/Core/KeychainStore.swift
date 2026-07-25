import Foundation
import Security

/// Stores the OpenRouter API key in the login keychain. Never logged,
/// never written to UserDefaults.
enum KeychainStore {
    /// Names one stored secret. Only the app's own key is ever stored under
    /// the default location; tests pass their own so the suite can never read
    /// or overwrite the key the user is actually dictating with.
    struct Location: Equatable {
        let service: String
        let account: String

        static let openRouterAPIKey = Location(
            service: "com.jonclegg.DogballWhisper", account: "openrouter-api-key")
    }

    private static func baseQuery(_ location: Location) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: location.service,
            kSecAttrAccount as String: location.account,
        ]
    }

    /// Saving an empty string is a no-op, not a deletion.
    ///
    /// This used to delete, and onboarding calls `save` unconditionally when
    /// you press "Start dictating", so a momentarily empty field wiped a
    /// working key — it silently vanished and cleanup then failed on every
    /// dictation with nothing on screen to explain why. Clearing the key is
    /// an explicit act, and both fields that hold it route an emptied field
    /// to `delete()` through `setKey(fromField:)`. Nothing else may treat an
    /// empty save as a revocation.
    @discardableResult
    static func save(_ key: String, at location: Location = .openRouterAPIKey) -> Bool {
        guard !key.isEmpty else { return true }
        delete(at: location)
        var query = baseQuery(location)
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(at location: Location = .openRouterAPIKey) -> String? {
        var query = baseQuery(location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// True when no key is stored afterwards, which includes there having
    /// been nothing to delete in the first place.
    @discardableResult
    static func delete(at location: Location = .openRouterAPIKey) -> Bool {
        let status = SecItemDelete(baseQuery(location) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Applies what a key field currently shows to the stored key: an empty
    /// or whitespace-only field revokes it, anything else replaces it.
    ///
    /// This is the only write path the UI uses, and it exists so that
    /// clearing the field means what it looks like it means. A user who
    /// deletes the key to stop sending their dictation to a third party gets
    /// it deleted, rather than an empty field over a key that is still stored
    /// and still used on every dictation.
    @discardableResult
    static func setKey(fromField text: String, at location: Location = .openRouterAPIKey) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? delete(at: location) : save(trimmed, at: location)
    }
}
