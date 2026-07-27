import CryptoKit
import Foundation

/// Verifies a third-party webhook signature: HMAC-SHA256 over the exact raw
/// body bytes, compared against the signature header the provider sent.
/// Byte preservation upstream is a hard invariant — the 4a relay carries the
/// body base64-encoded end-to-end precisely so this check sees the same bytes
/// the provider signed.
///
/// Header formats vary: GitHub sends `sha256=<hex>`, AgentMail/Stripe send
/// bare hex, svix sends base64. We strip the `sha256=` prefix if present and
/// accept hex or base64 encodings of the 32-byte MAC. The comparison itself
/// is CryptoKit's `isValidAuthenticationCode` — constant-time by contract.
func verifyHMACSHA256(rawBody: Data, headerValue: String, secret: String) -> Bool {
    var sig = headerValue.trimmingCharacters(in: .whitespaces)
    if sig.lowercased().hasPrefix("sha256=") {
        sig = String(sig.dropFirst("sha256=".count))
    }
    guard let mac = decodeMAC(sig) else { return false }
    let key = SymmetricKey(data: Data(secret.utf8))
    return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: rawBody, using: key)
}

/// Decode a candidate MAC string: 64 hex chars, else base64 of 32 bytes.
private func decodeMAC(_ s: String) -> Data? {
    if s.count == 64, let hex = Data(hexString: s) { return hex }
    if let b64 = Data(base64Encoded: s), b64.count == SHA256.byteCount { return b64 }
    return nil
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
