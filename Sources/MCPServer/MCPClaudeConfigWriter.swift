import Foundation

enum MCPClaudeConfigWriter {
    /// When `persistToken: true`, the bearer is read from / written to
    /// `~/.sonata/secrets/<sessionKey>.token` so the same token survives
    /// across Sonata restarts. Used for stable identities like
    /// "orchestrator" where live external claude sessions hold the
    /// token in memory and would 401 if it rotated under them.
    /// Workers/supervisor still use fresh-per-spawn tokens (default).
    static func writeAndRegister(
        sessionKey: String,
        role: SessionRole,
        registry: MCPSessionRegistry,
        port: Int = 3211,
        persistToken: Bool = false
    ) async throws -> MCPSessionCredential {
        guard MCPSessionKey.isValid(sessionKey) else {
            throw MCPError.invalidParams("invalid sessionKey")
        }
        let token: String
        if persistToken {
            token = try loadOrCreatePersistedToken(sessionKey: sessionKey)
        } else {
            token = MCPTokenGenerator.newToken()
        }
        let configPath = try ensureConfigDir().appendingPathComponent("\(sessionKey).json")

        let config: [String: Any] = [
            "mcpServers": [
                "memory": [
                    "type": "http",
                    "url": "http://localhost:\(port)/mcp-memory/\(sessionKey)",
                    "headers": ["Authorization": "Bearer \(token)"],
                ],
                "sonata-bridge": [
                    "type": "http",
                    "url": "http://localhost:\(port)/mcp/\(sessionKey)",
                    "headers": ["Authorization": "Bearer \(token)"],
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        let fm = FileManager.default
        try? fm.removeItem(at: configPath)
        let ok = fm.createFile(
            atPath: configPath.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        guard ok else {
            throw MCPError.internalError("failed to write per-session MCP config at \(configPath.path)")
        }

        await registry.registerToken(
            sessionKey: sessionKey, token: token, role: role)

        return MCPSessionCredential(
            sessionKey: sessionKey,
            bearerToken: token,
            configPath: configPath,
            role: role
        )
    }

    static func reconcileAll(
        workers: [String],
        supervisor: Bool,
        registry: MCPSessionRegistry,
        port: Int = 3211
    ) async throws {
        if supervisor {
            _ = try await writeAndRegister(
                sessionKey: "supervisor", role: .supervisor,
                registry: registry, port: port)
        }
        for workerId in workers {
            _ = try await writeAndRegister(
                sessionKey: workerId, role: .worker,
                registry: registry, port: port)
        }
    }

    private static func ensureConfigDir() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".sonata/mcp-cfg")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Atomically read/create a persisted token file at
    /// `~/.sonata/secrets/<sessionKey>.token`. Returns the existing
    /// contents if the file is present and well-formed; otherwise mints
    /// a fresh token and writes it (0600). Delete the file to rotate.
    private static func loadOrCreatePersistedToken(sessionKey: String) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".sonata/secrets")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("\(sessionKey).token")
        if let data = try? Data(contentsOf: file),
           let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // Sanity check: existing tokens are 64-hex from MCPTokenGenerator.
            // Anything else (manual corruption, partial write) → regenerate.
            if trimmed.count >= 32, trimmed.allSatisfy({ $0.isHexDigit }) {
                return trimmed
            }
        }
        let fresh = MCPTokenGenerator.newToken()
        let ok = FileManager.default.createFile(
            atPath: file.path,
            contents: Data(fresh.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard ok else {
            throw MCPError.internalError("failed to write persisted token at \(file.path)")
        }
        return fresh
    }
}
