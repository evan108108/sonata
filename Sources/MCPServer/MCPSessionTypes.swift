import Foundation

enum SessionRole: String, Sendable {
    case worker
    case supervisor
    case interactive
}

struct MCPSessionCredential: Sendable {
    let sessionKey: String
    let bearerToken: String
    let configPath: URL
    let role: SessionRole
}

enum MCPError: Error, Sendable {
    case parseError(String)
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)
    case unauthorized
    case sessionNotFound(String)
}

enum MCPTokenGenerator {
    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum MCPCryptoCompare {
    static func equals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }
}

enum MCPSessionKey {
    static let pattern = #"^[A-Za-z0-9_-]{1,128}$"#

    static func isValid(_ key: String) -> Bool {
        key.range(of: pattern, options: .regularExpression) != nil
    }
}
