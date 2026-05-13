import Foundation
import Security

/// Thin wrapper around macOS Keychain Services for Studio storage secrets.
///
/// Accounts are namespaced like:
///   - `studio-room-<slug>-s3-access-key`
///   - `studio-room-<slug>-s3-secret`
///   - `studio-default-s3-access-key`
///   - `studio-default-s3-secret`
///
/// Service name is fixed (`com.sonata.studio.storage`) so all Studio secrets
/// land in the same Keychain "bucket" the user can audit via Keychain Access.
enum StudioKeychain {

    private static let service = "com.sonata.studio.storage"

    enum KeychainError: Error, Equatable {
        case write(OSStatus)
        case read(OSStatus)
        case delete(OSStatus)
        case decode
    }

    // MARK: - Public API

    /// Store (or overwrite) a UTF-8 string secret under `account`.
    static func storeSecret(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.decode }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Try update-in-place first; fall back to add.
        let attrsToUpdate: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrsToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addAttrs = query
            addAttrs[kSecValueData as String] = data
            // Local accessibility — never sync; only this Mac, only when unlocked.
            addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.write(addStatus)
            }
            return
        }
        throw KeychainError.write(updateStatus)
    }

    /// Read a UTF-8 string secret previously stored under `account`.
    /// Returns nil when no item exists.
    static func readSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    /// Delete a stored secret. Non-existent items return successfully.
    static func deleteSecret(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    // MARK: - Account name helpers

    static func roomAccessKeyAccount(roomSlug: String) -> String {
        "studio-room-\(roomSlug)-s3-access-key"
    }

    static func roomSecretAccount(roomSlug: String) -> String {
        "studio-room-\(roomSlug)-s3-secret"
    }

    static func defaultAccessKeyAccount() -> String {
        "studio-default-s3-access-key"
    }

    static func defaultSecretAccount() -> String {
        "studio-default-s3-secret"
    }
}
