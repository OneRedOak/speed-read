import Foundation
import Security

/// Keychain-only credential storage (P-1).
///
/// The ElevenLabs API key lives in the login keychain as a generic
/// password, service "sr — ElevenLabs API Key", account "elevenlabs" —
/// the same attributes the `security` CLI writes, so keys added with
/// `security add-generic-password -a elevenlabs -s "sr — ElevenLabs API Key"`
/// are found here. No config file, no environment variable override.
public enum KeychainStore {
    public static let service = "sr — ElevenLabs API Key"
    public static let account = "elevenlabs"

    public static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    public static func saveAPIKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Try update first, then add.
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    public static func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Masked display form: last 4 characters only (P-1).
    public static func maskedAPIKey() -> String? {
        guard let key = readAPIKey() else { return nil }
        return "••••••••" + key.suffix(4)
    }
}
