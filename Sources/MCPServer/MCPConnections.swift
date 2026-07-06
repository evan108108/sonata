import Foundation

/// The HTTP layer's SSE connection table. One entry per attached MCP
/// session. Not a registry — it's just how a streaming HTTP server tracks
/// its own outbound streams. Only these operations matter externally:
///   • push a JSON-RPC notification to a session
///   • broadcast to all live streams
///   • ask whether a session currently has a live stream
///   • close a specific writer (used only by DELETE /mcp handlers)
///   • enumerate live keys (used only by the sweeper for heartbeat bumps)
///
/// State is process-scoped and non-durable by design. Reconnections
/// replace the entry; disconnects remove it. No snapshot, no getOrCreate —
/// sessions are looked up by DB, not by memory.
actor MCPConnections {
    private var writers: [String: MCPSSEWriter] = [:]

    /// Called by MCPHTTPRouter when an SSE GET succeeds and yields a writer.
    /// If a prior writer exists for this sessionKey (reconnect), close it so
    /// its stream terminates cleanly before we replace it.
    func attach(_ sessionKey: String, writer: MCPSSEWriter) {
        if let prior = writers[sessionKey] {
            prior.close()
        }
        writers[sessionKey] = writer
    }

    /// Called from the writer's onClose callback and from MCPHTTPRouter on
    /// DELETE /mcp. Idempotent. Only removes if the stored writer IS the
    /// one being detached — avoids racy detach removing a fresh reconnect's
    /// writer.
    func detach(_ sessionKey: String, writer: MCPSSEWriter) {
        if let current = writers[sessionKey], current === writer {
            writers.removeValue(forKey: sessionKey)
        }
    }

    /// True if there's a live (non-closed) SSE stream for this sessionKey.
    func hasLive(_ sessionKey: String) -> Bool {
        guard let w = writers[sessionKey] else { return false }
        return !w.isClosed
    }

    /// Push a JSON-RPC notification frame to the sessionKey's SSE stream.
    /// Returns true if pushed to a live writer, false otherwise. Does not
    /// wait for any acknowledgement — that's a separate application-level
    /// concern (see dm_ack flow).
    func push(_ sessionKey: String, jsonRPC: String) -> Bool {
        guard let w = writers[sessionKey], !w.isClosed else { return false }
        w.send(jsonRPC: jsonRPC)
        return true
    }

    /// Broadcast to every live writer, optionally excluding a set of keys
    /// (used by dm_broadcast to exclude the sender). Returns the count of
    /// writers pushed to.
    @discardableResult
    func broadcast(jsonRPC: String, excluding: Set<String> = []) -> Int {
        var count = 0
        for (key, w) in writers where !w.isClosed && !excluding.contains(key) {
            w.send(jsonRPC: jsonRPC)
            count += 1
        }
        return count
    }

    /// Send SSE keep-alive frames on every live writer. Called by the
    /// periodic sweeper. Idempotent.
    func tickKeepAlives() {
        for w in writers.values where !w.isClosed {
            w.sendKeepAlive()
        }
    }

    /// Enumerate all currently-live sessionKeys. Used only by
    /// MCPSessionSweeper to know which DB rows need heartbeat bumps.
    /// NOT exposed via any HTTP or MCP API.
    func liveSessionKeys() -> [String] {
        writers.filter { !$0.value.isClosed }.map { $0.key }
    }

    /// Close the writer for `sessionKey` if it's currently live. The
    /// writer's onClose callback (installed by MCPHTTPRouter) then fires
    /// detach() + MCPAuth.revoke(). Used only by DELETE /mcp handlers.
    func closeIfLive(_ sessionKey: String) {
        if let w = writers[sessionKey], !w.isClosed {
            w.close()
        }
    }
}

extension MCPConnections {
    /// Process-singleton. The HTTP layer is naturally singleton-per-process.
    /// Callers use this via `MCPConnections.shared`.
    static let shared = MCPConnections()
}
