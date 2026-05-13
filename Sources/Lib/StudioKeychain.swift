import Foundation

/// File-based secret store for Studio storage credentials.
///
/// Lives under `~/.sonata/private/studio-storage/<account>.txt` with 0600
/// permissions. The macOS Keychain is the obvious home for these but its
/// ACL is bound to the writing binary's code signature, and Sonata's
/// development binaries are ad-hoc-signed — each rebuild creates a new
/// signature and macOS re-prompts for the keychain password on every
/// secret read. File storage with 0600 is equivalent security for a
/// single-user dev tool (the directory is already where Sonata stores
/// other private material like signing keys) and costs zero prompts.
///
/// Type name kept as `StudioKeychain` so callers don't need to change.
enum StudioKeychain {

    enum KeychainError: Error, Equatable {
        case write(Int32)
        case decode
    }

    private static var storeDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".sonata", isDirectory: true)
            .appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("studio-storage", isDirectory: true)
    }

    private static func ensureDir() throws {
        let dir = storeDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
    }

    private static func fileURL(account: String) -> URL {
        // Sanitize: account names already use [a-z0-9-]; reject anything else
        // to avoid path-escape surprises.
        let safe = account.unicodeScalars.map { sc -> Character in
            if (sc.value >= 0x30 && sc.value <= 0x39) // 0-9
                || (sc.value >= 0x41 && sc.value <= 0x5A) // A-Z
                || (sc.value >= 0x61 && sc.value <= 0x7A) // a-z
                || sc.value == 0x2D || sc.value == 0x5F { // - _
                return Character(sc)
            }
            return "_"
        }
        return storeDir.appendingPathComponent(String(safe) + ".txt")
    }

    // MARK: - Public API

    /// Store (or overwrite) a UTF-8 string secret under `account`.
    static func storeSecret(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.decode }
        try ensureDir()
        let url = fileURL(account: account)
        try data.write(to: url, options: [.atomic])
        // chmod 600 — single-user dev tool, no group/other access.
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }

    /// Read a UTF-8 string secret previously stored under `account`.
    /// Returns nil when no item exists.
    static func readSecret(account: String) -> String? {
        let url = fileURL(account: account)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a stored secret. Non-existent items return successfully.
    static func deleteSecret(account: String) {
        let url = fileURL(account: account)
        try? FileManager.default.removeItem(at: url)
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
