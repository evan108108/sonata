import Foundation

/// Bearer tokens for MCP session authentication. Ephemeral, process-scoped.
/// Not a registry — just a token store used exclusively by the auth path.
/// Tokens are minted by `MCPClaudeConfigWriter.writeAndMint` at spawn
/// time and validated by MCPHTTPRouter on incoming requests.
actor MCPAuth {
    private var tokens: [String: String] = [:]

    func mint(sessionKey: String, token: String) {
        tokens[sessionKey] = token
    }

    func rotate(sessionKey: String) -> String {
        let newToken = MCPTokenGenerator.newToken()
        tokens[sessionKey] = newToken
        return newToken
    }

    func validate(sessionKey: String, supplied: String?) -> Bool {
        guard let supplied else { return false }
        guard let expected = tokens[sessionKey] else { return false }
        return MCPCryptoCompare.equals(expected, supplied)
    }

    func revoke(sessionKey: String) {
        tokens.removeValue(forKey: sessionKey)
    }

    static let shared = MCPAuth()
}
