import Foundation

/// Renderer-side lookup for S3 credentials at upload time.
///
/// The Studio plugin never holds raw S3 keys — they live in the macOS
/// Keychain. When the compose sheet calls `studio_file_attach` or
/// `studio_image_attach`, the renderer resolves credentials from Keychain
/// in priority order (room override → user default) and slips them into the
/// action body. The plugin uses them in-memory only.
enum StudioStorageCredentials {

    struct Pair {
        let accessKeyId: String
        let secretAccessKey: String

        var body: [String: Any] {
            ["access_key_id": accessKeyId, "secret_access_key": secretAccessKey]
        }
    }

    /// Resolve the most specific (room-scoped) credential pair, then fall
    /// back to the user-wide default. Returns nil when neither location has
    /// a complete pair — callers should not include `s3_credentials` in the
    /// upload body in that case.
    static func lookup(forRoom roomSlug: String) -> Pair? {
        if let pair = pair(
            access: StudioKeychain.roomAccessKeyAccount(roomSlug: roomSlug),
            secret: StudioKeychain.roomSecretAccount(roomSlug: roomSlug)
        ) {
            return pair
        }
        return pair(
            access: StudioKeychain.defaultAccessKeyAccount(),
            secret: StudioKeychain.defaultSecretAccount()
        )
    }

    private static func pair(access: String, secret: String) -> Pair? {
        guard let id = StudioKeychain.readSecret(account: access),
              !id.isEmpty,
              let sec = StudioKeychain.readSecret(account: secret),
              !sec.isEmpty
        else {
            return nil
        }
        return Pair(accessKeyId: id, secretAccessKey: sec)
    }
}
