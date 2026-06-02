import Foundation

enum MCPClaudeConfigWriter {
    static func writeAndRegister(
        sessionKey: String,
        role: SessionRole,
        registry: MCPSessionRegistry,
        port: Int = 3211
    ) async throws -> MCPSessionCredential {
        guard MCPSessionKey.isValid(sessionKey) else {
            throw MCPError.invalidParams("invalid sessionKey")
        }
        let token = MCPTokenGenerator.newToken()
        let configPath = try ensureConfigDir().appendingPathComponent("\(sessionKey).json")

        // Single unified MCP server — see ~/.sonata/wiki/sonata/mcp-identity.md
        // ("The single rule"). The `/mcp/:sessionKey` endpoint serves the
        // entire tool surface (236 tools, incl. all 76 mem_* tools), so one
        // server entry is all a session needs.
        //
        // A second "memory" entry pointing at `/mcp-memory/:sessionKey` used
        // to be emitted here, but MCPHTTPRouter never registered that route —
        // it 404'd from day one, surfacing as a low-visibility "Failed to
        // reconnect to memory" in the /mcp panel while the mem_* tools kept
        // working through sonata-bridge. Emitting only the route that exists
        // removes the config↔route divergence permanently.
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
}
