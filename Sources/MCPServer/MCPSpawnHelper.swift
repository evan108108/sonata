import Foundation

/// Centralizes the `SONATA_MCP_INPROC` opt-in branch for every coordinator
/// that spawns a claude subprocess. When enabled, issues a per-session
/// bearer token via MCPAuth, writes the per-session `--mcp-config` file,
/// and returns the extra args. When disabled or on failure, returns nil
/// and the caller stays on its legacy env-var bridge path.
enum MCPSpawn {
    /// In-proc MCP is the default. Set `SONATA_MCP_INPROC=0` to fall back.
    static var inProcEnabled: Bool {
        ProcessInfo.processInfo.environment["SONATA_MCP_INPROC"] != "0"
    }

    static var slotAllowlist: Set<String>? {
        guard let raw = ProcessInfo.processInfo.environment["SONATA_MCP_INPROC_LABELS"],
              !raw.isEmpty else { return nil }
        let labels = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return labels.isEmpty ? nil : Set(labels)
    }

    /// Issue credentials + write per-session --mcp-config for `sessionKey`,
    /// returning the extra args. Returns nil if the in-proc path is not
    /// active, the slot isn't in the allowlist (when set), or the credential
    /// write failed.
    static func extraArgsForInProcMCP(
        sessionKey: String,
        role: SessionRole,
        slotLabel: String? = nil
    ) -> [String]? {
        guard inProcEnabled else { return nil }
        if let allowlist = slotAllowlist {
            guard let label = slotLabel, allowlist.contains(label) else {
                return nil
            }
        }
        do {
            let cred = try awaitSyncMCPCredential(sessionKey: sessionKey, role: role)
            return ["--mcp-config", cred.configPath.path]
        } catch {
            FileHandle.standardError.write(Data("[mcp-spawn] FATAL: credential write failed for sessionKey=\(sessionKey): \(error) — session will spawn WITHOUT MCP attach.\n".utf8))
            return nil
        }
    }
}

/// Run the async credential write synchronously. <20ms in practice.
private func awaitSyncMCPCredential(
    sessionKey: String,
    role: SessionRole
) throws -> MCPSessionCredential {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<MCPSessionCredential, Error>!
    Task.detached {
        do {
            let cred = try await MCPClaudeConfigWriter.writeAndMint(
                sessionKey: sessionKey, role: role, auth: MCPAuth.shared)
            result = .success(cred)
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
