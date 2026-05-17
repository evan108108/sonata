import Foundation

/// Centralizes the `SONATA_MCP_INPROC=1` opt-in branch for every
/// coordinator that spawns a claude subprocess (Supervisor, Worker,
/// Interactive, Inspector). When the flag is set AND a shared
/// MCPSessionRegistry is published, this helper issues a per-session
/// bearer token, writes the per-session `--mcp-config` file via
/// MCPClaudeConfigWriter, and returns the extra args to append to the
/// claude command line. When the flag is unset (or anything fails),
/// returns an empty extras list and the caller stays on its existing
/// env-var bridge path — i.e. behaviour is byte-for-byte identical to
/// pre-§6 when SONATA_MCP_INPROC is not set.
enum MCPSpawn {
    /// Whether the current process environment has opted into in-proc MCP.
    static var inProcEnabled: Bool {
        ProcessInfo.processInfo.environment["SONATA_MCP_INPROC"] == "1"
    }

    /// Issue credentials + write per-session --mcp-config for `sessionKey`,
    /// returning the extra args (`["--mcp-config", "<path>"]`) to append
    /// to the claude command line. Returns nil if the in-proc path is not
    /// active, registry isn't published yet, or the credential write
    /// failed — caller falls back to legacy env-var spawning.
    static func extraArgsForInProcMCP(
        sessionKey: String,
        role: SessionRole
    ) -> [String]? {
        guard inProcEnabled else { return nil }
        guard let registry = MCPSessionRegistry.shared else {
            FileHandle.standardError.write(Data("[mcp-spawn] SONATA_MCP_INPROC set but MCPSessionRegistry.shared not yet published — falling back to legacy bridge for sessionKey=\(sessionKey)\n".utf8))
            return nil
        }
        do {
            let cred = try awaitSyncMCPCredential(sessionKey: sessionKey, role: role, registry: registry)
            return ["--mcp-config", cred.configPath.path]
        } catch {
            FileHandle.standardError.write(Data("[mcp-spawn] credential write failed for sessionKey=\(sessionKey): \(error) — falling back to legacy bridge\n".utf8))
            return nil
        }
    }
}

/// Run an async credential write synchronously. startProcess call sites
/// are synchronous and the underlying work is local-disk + a single
/// actor hop, measured <20ms — well within the budget for a sync block
/// on the main thread (Pass B B4). Kept private-to-MCP so call sites
/// don't accidentally use it for heavier work.
private func awaitSyncMCPCredential(
    sessionKey: String,
    role: SessionRole,
    registry: MCPSessionRegistry
) throws -> MCPSessionCredential {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<MCPSessionCredential, Error>!
    Task.detached {
        do {
            let cred = try await MCPClaudeConfigWriter.writeAndRegister(
                sessionKey: sessionKey, role: role, registry: registry)
            result = .success(cred)
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
