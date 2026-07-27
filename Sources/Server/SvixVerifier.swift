import CryptoKit
import Foundation

/// Verifies a Svix-signed webhook (AgentMail and hundreds of other providers
/// that use Svix as their webhook infra). Svix signs the concatenation
/// `{svix-id}.{svix-timestamp}.{raw-body}` with a `whsec_`-prefixed secret
/// whose payload after the prefix is base64-encoded key material. Result is
/// base64 HMAC-SHA256, presented as one or more space-separated `v1,<sig>`
/// candidates in the `svix-signature` header (multiple during key rotation).
///
/// Enforces a timestamp tolerance (default 5 minutes) to reject trivial
/// replays — matches Svix's own recommendation.
///
/// Byte preservation upstream is a hard invariant — the 4a relay carries the
/// exact request bytes base64-encoded end-to-end precisely so this check sees
/// the same bytes Svix signed.
func verifySvixSignature(
    rawBody: Data,
    svixId: String,
    svixTimestamp: String,
    svixSignature: String,
    secret: String,
    toleranceSeconds: Int = 5 * 60,
    now: Date = Date()
) -> Bool {
    // 1. Timestamp within tolerance (Svix documented replay defense).
    guard let ts = Int(svixTimestamp) else { return false }
    let nowSec = Int(now.timeIntervalSince1970)
    guard abs(nowSec - ts) <= toleranceSeconds else { return false }

    // 2. Strip `whsec_` prefix, base64-decode the rest → key material.
    let rawSecret = secret.hasPrefix("whsec_")
        ? String(secret.dropFirst("whsec_".count))
        : secret
    guard let keyData = Data(base64Encoded: rawSecret) else { return false }

    // 3. Build the signed payload: id.timestamp.body (byte-exact).
    var payload = Data()
    guard let idBytes = svixId.data(using: .utf8),
          let tsBytes = svixTimestamp.data(using: .utf8) else { return false }
    payload.append(idBytes)
    payload.append(0x2E) // "."
    payload.append(tsBytes)
    payload.append(0x2E)
    payload.append(rawBody)

    // 4. Compute expected HMAC-SHA256 → base64.
    let key = SymmetricKey(data: keyData)
    let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
    let expected = Data(mac).base64EncodedString()

    // 5. Any `v1,<sig>` candidate matches → verified. Constant-time compare.
    for candidate in svixSignature.split(separator: " ") {
        let parts = candidate.split(separator: ",", maxSplits: 1)
        guard parts.count == 2, parts[0] == "v1" else { continue }
        if constantTimeEquals(String(parts[1]), expected) { return true }
    }
    return false
}

private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8), bBytes = Array(b.utf8)
    guard aBytes.count == bBytes.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
    return diff == 0
}
