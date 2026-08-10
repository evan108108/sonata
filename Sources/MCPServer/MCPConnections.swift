import Foundation
import GRDB

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

    /// Monotonic counter bumped every time the tool surface changes
    /// (plugin registered / crashed / disabled). Used to detect writers
    /// that were disconnected across a mutation and need a replay on
    /// reconnect.
    private var toolsListEpoch: Int = 0

    /// Per-session record of the last epoch this session was told about.
    /// A reconnecting session whose value is behind `toolsListEpoch`
    /// missed a mutation while its stream was down — attach() replays
    /// `tools/list_changed` so the client re-pulls tools/list. Kept
    /// across detach — the same session key can reconnect.
    private var lastPushedEpoch: [String: Int] = [:]

    /// Called by MCPHTTPRouter when an SSE GET succeeds and yields a writer.
    /// If a prior writer exists for this sessionKey (reconnect), close it so
    /// its stream terminates cleanly before we replace it.
    ///
    /// Reconnect-replay of tools/list_changed: if the tool surface mutated
    /// while this session was disconnected, push list_changed to the new
    /// writer so the client refreshes. Without this, a client that
    /// reconnects between Sonata's HTTP-up and plugin discovery holds an
    /// incomplete tool surface forever — the broadcast that would have
    /// told them never reached them, because their writer wasn't attached
    /// when it fired. (2026-08-10 ADA report: post-restart clients saw
    /// bridge-native tools but not plugin proxies like prstar_*.)
    func attach(_ sessionKey: String, writer: MCPSSEWriter) {
        if let prior = writers[sessionKey] {
            prior.close()
        }
        writers[sessionKey] = writer
        if (lastPushedEpoch[sessionKey] ?? 0) < toolsListEpoch {
            writer.send(jsonRPC: Self.toolsListChangedFrame)
            lastPushedEpoch[sessionKey] = toolsListEpoch
        }
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

    /// Push to a worker's SSE stream given EITHER its workerId or its Claude
    /// sessionId. `push` above is strict — you must know the exact SSE key,
    /// which for workers is the workerId (set by MCPHTTPRouter when the
    /// bridge attached to `/mcp/:workerId`). Callers that track worker
    /// identity by sessionId (dm-subsystem, workers.sessionId column) would
    /// silently no-op against a live worker without this helper. Order:
    ///   1. try `identifier` directly (fast path for callers already holding
    ///      the correct workerId key);
    ///   2. else look up `workers` in `dbPool` by BOTH columns, translate,
    ///      retry.
    func pushToWorker(identifier: String, jsonRPC: String, dbPool: DatabasePool) async -> Bool {
        if push(identifier, jsonRPC: jsonRPC) { return true }

        // Fall through: identifier isn't a live SSE key. Translate via DB.
        // A single row query covers both directions — either column may match.
        let translated: String? = try? await dbPool.read { db in
            try String.fetchOne(db, sql: """
                SELECT workerId FROM workers
                WHERE workerId = ? OR sessionId = ?
                LIMIT 1
            """, arguments: [identifier, identifier])
        }
        guard let key = translated, key != identifier else { return false }
        return push(key, jsonRPC: jsonRPC)
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

    /// Notify every live writer that the tool surface changed. Bumps the
    /// epoch so any writer currently detached will be replayed on its
    /// next attach. Called by MCPNotificationDispatcher whenever the
    /// ActionRegistry mutates (plugin register / crash / disable).
    /// Returns the count of writers immediately pushed to.
    @discardableResult
    func broadcastToolsListChanged() -> Int {
        toolsListEpoch += 1
        var count = 0
        for (key, w) in writers where !w.isClosed {
            w.send(jsonRPC: Self.toolsListChangedFrame)
            lastPushedEpoch[key] = toolsListEpoch
            count += 1
        }
        return count
    }

    /// The JSON-RPC frame for `notifications/tools/list_changed`. Params
    /// are empty by MCP spec — the receiver re-fetches tools/list. Held
    /// as a static constant so the hot path (broadcast fans out to every
    /// writer) does not re-serialize.
    private static let toolsListChangedFrame =
        #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}"#
}

extension MCPConnections {
    /// Process-singleton. The HTTP layer is naturally singleton-per-process.
    /// Callers use this via `MCPConnections.shared`.
    static let shared = MCPConnections()
}
