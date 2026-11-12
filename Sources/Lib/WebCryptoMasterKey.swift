import Foundation
import Security

/// The master key WebKit uses to wrap every CryptoKey a page persists
/// (e.g. a non-extractable key stored in IndexedDB).
///
/// By default WebKit reads this key from the login-keychain item
/// "Sonata WebCrypto Master Key". It does that synchronously, on the main
/// thread, in response to a sync IPC from the web process. Sonata is ad-hoc
/// signed, so every deploy-local produces a new cdhash, and that cdhash is not
/// in the item's ACL. The first WebCrypto page after a deploy therefore raises
/// a keychain dialog, and the whole main actor (every webview verb, the
/// window) freezes until someone answers it. That happened on 2026-11-11 from
/// ~14:02Z (memory ef3f2a45).
///
/// Every Sonata WKNavigationDelegate implements WebKit's private
/// `_webCryptoMasterKeyForWebView:` (plus its completion-handler variant) and
/// returns `WebCryptoMasterKey.data`, so WebKit never touches the keychain.
/// The key lives in SecretStore for the same reason StudioKeychain moved off
/// the keychain: ad-hoc signatures make keychain ACLs churn on every rebuild.
///
/// One-time cost: keys that pages wrapped under the old keychain master key
/// can no longer be unwrapped, so a site holding one in IndexedDB re-creates
/// it (or asks the user to sign in again).
enum WebCryptoMasterKey {
    static let secretName = "SONATA_WEBCRYPTO_MASTER_KEY"

    /// WebKit's own default master key is AES-128 (kCCKeySizeAES128).
    static let sizeInBytes = 16

    /// Loaded once per process. WebKit asks on the main thread and expects an
    /// immediate answer, so this must never block on I/O beyond the first
    /// UserDefaults read. A `static let` initializer runs exactly once and is
    /// thread-safe.
    static let data: Data? = loadOrCreate()

    private static func loadOrCreate() -> Data? {
        if let stored = SecretStore.get(secretName) {
            if let decoded = Data(base64Encoded: stored), decoded.count == sizeInBytes {
                return decoded
            }
            sonataFileLog("WebCryptoMasterKey: stored \(secretName) is not \(sizeInBytes) base64 bytes; replacing it")
        }
        guard let fresh = randomKey() else {
            sonataFileLog("WebCryptoMasterKey: SecRandomCopyBytes failed; WebKit gets no master key this run")
            return nil
        }
        SecretStore.set(
            name: secretName,
            value: fresh.base64EncodedString(),
            description: "WebKit WebCrypto master key (base64, AES-128). Replaces the keychain item so ad-hoc deploys never raise a keychain dialog. Changing it orphans keys sites stored in IndexedDB."
        )
        return fresh
    }

    private static func randomKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: sizeInBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, sizeInBytes, &bytes)
        return status == errSecSuccess ? Data(bytes) : nil
    }
}
