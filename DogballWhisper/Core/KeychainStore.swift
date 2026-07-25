import Foundation
import Security

/// Stores the OpenRouter API key in the login keychain. Never logged,
/// never written to UserDefaults.
enum KeychainStore {
    private static let service = "com.jonclegg.DogballWhisper"
    private static let account = "openrouter-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    /// Saving an empty string is a no-op, not a deletion.
    ///
    /// This used to delete: onboarding calls `save` unconditionally when you
    /// press "Start dictating", and its field does not prefill from the
    /// keychain, so re-running setup with an already-stored key wiped it — the
    /// key silently vanished and cleanup then failed on every dictation with
    /// nothing on screen to explain why. Clearing the key is an explicit act;
    /// use `delete()`.
    static func save(_ key: String) -> Bool {
        guard !key.isEmpty else { return true }
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = baseQuery
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

    @discardableResult
    static func delete() -> Bool {
        SecItemDelete(baseQuery as CFDictionary) == errSecSuccess
    }
}
