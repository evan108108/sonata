import Foundation
import GRDB
import Logging
import NIOCore
@testable import Sonata

// MCP in-app server test harness. Stateless-JSON-RPC edition.
//
// Since ecfb094 ("eradicate MCPSessionRegistry/MCPSessionState — DB is the
// sole identity source"), there's no per-session actor to hand tests. The
// current server model is `MCPHandshake.handle(...)` — a static function
// that takes sessionKey/role as parameters and reads any per-session state
// from the shared DB. This harness mirrors that: it provisions the DB and
// action registry once, then exposes a `handle(...)` shim that calls the
// production entry point with the parameters spelled out.
//
// Each instance is fully isolated — separate DB file, separate registries,
// fresh MCPNotificationDispatcher (not .shared) so tests don't fight over
// the global singleton's one-shot bind.
//
// No Hummingbird HTTP server. Tests hit `MCPHandshake.handle` directly —
// the HTTP router is a thin shim over it, and isolating from the network
// removes the flake surface random-port harnesses bring.
struct MCPTestHarness {
    let dbPool: DatabasePool
    let actionRegistry: ActionRegistry
    let dispatcher: MCPNotificationDispatcher
    private let dbPath: String

    static func make() throws -> MCPTestHarness {
        let dbPath = NSTemporaryDirectory() + "sonata-mcp-test-\(UUID().uuidString).sqlite"
        let pool = try DatabasePool(path: dbPath)

        var migrator = DatabaseMigrator()
        migrator.registerSonataSchema()
        try migrator.migrate(pool)

        let actions = ActionRegistry()
        actions.register(workerActions)
        actions.register(workerEventActions)
        actions.register(supervisorActions)
        actions.register(dmActions)
        actions.register(taskActions)
        actions.register(taskWatcherActions)

        let dispatcher = MCPNotificationDispatcher()

        return MCPTestHarness(
            dbPool: pool,
            actionRegistry: actions,
            dispatcher: dispatcher,
            dbPath: dbPath
        )
    }

    func teardown() {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    /// Dispatch a single JSON-RPC method through the production
    /// `MCPHandshake.handle` entrypoint. Returns the raw JSON response
    /// string (or nil for notifications). Sessions are represented by
    /// sessionKey + role — the current stateless model doesn't require
    /// pre-registration for handshake or tools/call to work.
    func handle(
        sessionKey: String,
        role: SessionRole = .worker,
        method: String,
        id: Any?,
        params: [String: Any]
    ) async -> String? {
        return await MCPHandshake.handle(
            method: method,
            id: id,
            params: params,
            sessionKey: sessionKey,
            role: role,
            actionRegistry: actionRegistry,
            dbPool: dbPool
        )
    }
}

// Collect SSE frames off an AsyncStream<ByteBuffer> until either the timeout
// elapses (which closes the writer to terminate the stream cleanly) or the
// predicate matches. Returns the data: payloads in order. Assertion shape
// becomes "frame arrived within N ms" rather than "frame eventually arrived"
// — the latter hides regressions when latency creeps past Phase C's gate.
enum MCPSSEFrameCollector {
    static func collect(
        from writer: MCPSSEWriter,
        timeout: TimeInterval,
        until matches: @escaping @Sendable (String) -> Bool = { _ in false }
    ) async -> [String] {
        let timeoutTask = Task { [weak writer] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            writer?.close()
        }
        var frames: [String] = []
        var buffer = ""
        for await chunk in writer.stream {
            let s = chunk.getString(at: chunk.readerIndex, length: chunk.readableBytes) ?? ""
            buffer += s
            while let end = buffer.range(of: "\n\n") {
                let block = String(buffer[..<end.lowerBound])
                buffer.removeSubrange(..<end.upperBound)
                for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.hasPrefix("data: ") {
                        let payload = String(line.dropFirst("data: ".count))
                        frames.append(payload)
                        if matches(payload) {
                            timeoutTask.cancel()
                            return frames
                        }
                    }
                }
            }
        }
        timeoutTask.cancel()
        return frames
    }
}
