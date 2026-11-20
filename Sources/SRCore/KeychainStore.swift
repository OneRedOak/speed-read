import Foundation
import Security

/// Keychain-only credential storage (P-1).
///
/// The ElevenLabs API key lives in the login keychain as a generic
/// password, service "sr — ElevenLabs API Key", account "elevenlabs" —
/// the same attributes the `security` CLI writes, so keys added with
/// `security add-generic-password -a elevenlabs -s "sr — ElevenLabs API Key"`
/// are found here. No config file, no environment variable override.
///
/// An in-memory read cache avoids synchronous Keychain IPC on every
/// synthesized sentence and SwiftUI render; writes/deletes update it
/// immediately, and `invalidateCache()` refreshes from the Keychain
/// (e.g., when Settings opens or after an auth failure).
public enum KeychainStore {
    public static let service = "sr — ElevenLabs API Key"
    public static let account = "elevenlabs"

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var loaded = false
        var key: String?
    }
    private static let cache = Cache()

    public static func readAPIKey() -> String? {
        if let cached = cache.lock.withLock({ cache.loaded ? Optional.some(cache.key) : nil }) {
            return cached
        }
        let fetched = readAPIKeyFromKeychain()
        cache.lock.withLock {
            cache.key = fetched
            cache.loaded = true
        }
        return fetched
    }

    /// Force the next read to query the macOS Keychain directly (picks up keys
    /// added or rotated externally via the `security` CLI or Keychain Access).
    public static func invalidateCache() {
        cache.lock.withLock {
            cache.loaded = false
            cache.key = nil
        }
    }

    private static func readAPIKeyFromKeychain() -> String? {
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
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let data = Data(trimmed.utf8)
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
        if status == errSecSuccess {
            cache.lock.withLock {
                cache.key = trimmed
                cache.loaded = true
            }
            return true
        }
        return false
    }

    @discardableResult
    public static func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            cache.lock.withLock {
                cache.key = nil
                cache.loaded = true
            }
            return status == errSecSuccess
        }
        return false
    }

    /// Masked display form: last 4 characters only (P-1).
    public static func maskedAPIKey() -> String? {
        guard let key = readAPIKey() else { return nil }
        return "••••••••" + key.suffix(4)
    }
}
