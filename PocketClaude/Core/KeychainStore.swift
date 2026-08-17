import Foundation
import Security

/// Secrets live here and nowhere else.
///
/// Swift note: `UserDefaults` is the tempting `localStorage` analogue, but it is
/// a plain plist inside the app container and is included in unencrypted
/// backups. The Keychain is the only appropriate place for API keys.
enum KeychainStore {
    /// One entry per secret. `rawValue` is the Keychain account name.
    enum Key: String, CaseIterable {
        case anthropicAPIKey = "anthropic.api.key"
        case githubToken = "github.pat"
        case elevenLabsAPIKey = "elevenlabs.api.key"
        /// Bearer token for your own relay — must match RELAY_TOKEN there.
        case relayToken = "relay.token"
    }

    private static let service = "com.pocketclaude.secrets"

    /// Writes (or overwrites) a secret. Passing nil or an empty string deletes it.
    @discardableResult
    static func set(_ value: String?, for key: Key) -> Bool {
        guard let value, !value.isEmpty else { return delete(key) }
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]

        // Try update first; fall back to add. (SecItemAdd fails with
        // errSecDuplicateItem if the entry already exists.)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var insert = query
        insert[kSecValueData as String] = data
        // Available after first unlock so a backgrounded session can still refresh.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(_ key: Key) -> Bool { get(key) != nil }
}
