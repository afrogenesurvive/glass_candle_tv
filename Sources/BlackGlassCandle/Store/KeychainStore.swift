import Foundation
import Security

/// The API password, stored in the macOS login Keychain.
///
/// Why the Keychain and not `UserDefaults`:
///   - `UserDefaults` is a plist in `~/Library/Preferences`. It is readable by
///     anything running as the user and it lands in every backup and migration.
///   - The Keychain encrypts at rest, is released with the user account, and can
///     be scoped and revoked per item.
///
/// A hand-rolled alternative — encrypting keys with AES-GCM against a key file on
/// disk — also works, but it adds a key-file lifecycle (permissions, backup,
/// migration, "where did the key go") for no security gain over the Keychain.
///
/// This type is intentionally not an actor: every operation is a synchronous
/// call into the Security framework, and `SecItem*` is already thread-safe.
enum KeychainStore {

    /// Must match `KEYCHAIN_SERVICE` in scripts/seed_menubar_config.sh.
    static let service = "black_glass_candle"
    /// Must match `KEYCHAIN_ACCOUNT` in scripts/seed_menubar_config.sh.
    static let account = "api-password"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or replace) the API password.
    @discardableResult
    static func save(_ password: String) -> Bool {
        let data = Data(password.utf8)

        // Delete-then-add is simpler and more predictable than SecItemUpdate,
        // which needs a different query shape depending on whether the item
        // exists. The window between the two calls is irrelevant for a
        // single-user local credential.
        SecItemDelete(baseQuery() as CFDictionary)

        var query = baseQuery()
        query[kSecValueData as String] = data
        // The app runs unsandboxed, so this only means "available after first
        // unlock" rather than "available to other apps".
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            // A locked, unavailable or otherwise unhappy keychain is worth
            // surfacing rather than swallowing — the alternative is an app that
            // silently forgets its password every launch.
            print("[KeychainStore] save failed: \(KeychainError.unexpectedStatus(status).localizedDescription)")
            return false
        }
        return true
    }

    /// Read the API password, or nil if it has not been set.
    static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    static func exists() -> Bool {
        load() != nil
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
