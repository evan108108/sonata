import Foundation

enum MCPClaudeConfigWriter {
    /// Mint a per-session bearer token, register it with MCPAuth, write the
    /// per-session `--mcp-config` file, and return the credential.
    static func writeAndMint(
        sessionKey: String,
        role: SessionRole,
        auth: MCPAuth,
        port: Int = 3211
    ) async throws -> MCPSessionCredential {
        guard MCPSessionKey.isValid(sessionKey) else {
            throw MCPError.invalidParams("invalid sessionKey")
        }
        let token = MCPTokenGenerator.newToken()
        let configPath = try ensureConfigDir().appendingPathComponent("\(sessionKey).json")

        // Single unified MCP server — see ~/.sonata/wiki/sonata/mcp-identity.md.
        let config: [String: Any] = [
            "mcpServers": [
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

        await auth.mint(sessionKey: sessionKey, token: token)

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
        auth: MCPAuth,
        port: Int = 3211
    ) async throws {
        if supervisor {
            _ = try await writeAndMint(
                sessionKey: "supervisor", role: .supervisor,
                auth: auth, port: port)
        }
        for workerId in workers {
            _ = try await writeAndMint(
                sessionKey: workerId, role: .worker,
                auth: auth, port: port)
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
}
