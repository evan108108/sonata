import Foundation
import GRDB
import Logging
import NIOCore
@testable import Sonata

// MCP in-app server test harness. Plan §9.
//
// Boots:
// - GRDB DatabasePool against a per-test temp sqlite file (the DM tests use
//   the same pattern; :memory: refuses WAL).
// - Full Sonata schema via DatabaseMigrator.registerSonataSchema (G2 gate —
//   plan called this Schema.applyMigrations(pool); the real entrypoint is
//   the DatabaseMigrator extension).
// - ActionRegistry with the modules MCPToolHandlers can dispatch into
//   (workerEvents, supervisor, AFK, DM) so executeMCPTool resolves them.
//   Plan §9 called this ActionRegistry.registerAll(into:); the real surface
//   is registry.register([...]) per module, mirroring SonataApp.swift.
// - MCPSessionRegistry wired to the pool + ActionRegistry.
//
// Each instance is fully isolated — separate DB file, separate registries,
// fresh MCPNotificationDispatcher (not .shared) so tests don't fight over
// the global singleton's one-shot bind.
//
// No Hummingbird HTTP server. Tests exercise MCPSessionState / registry /
// SSE writer / dispatcher directly via their actor APIs — the HTTP router
// is a thin shim over those, and isolating from the network removes the
// flake surface that random-port HTTP harnesses bring (Hummingbird 2's
// resolvedPort accessor varies across patch versions, and tests that bind
// real ports race the OS allocator under parallel test execution).
struct MCPTestHarness {
    let dbPool: DatabasePool
    let actionRegistry: ActionRegistry
    let mcpRegistry: MCPSessionRegistry
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
        actions.register(afkActions)
        actions.register(dmActions)
        actions.register(taskActions)
        actions.register(taskWatcherActions)

        let mcpRegistry = MCPSessionRegistry(dbPool: pool, actionRegistry: actions)
        let dispatcher = MCPNotificationDispatcher()

        return MCPTestHarness(
            dbPool: pool,
            actionRegistry: actions,
            mcpRegistry: mcpRegistry,
            dispatcher: dispatcher,
            dbPath: dbPath
        )
    }

    func teardown() {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    // Convenience: register a fresh session with a known bearer token and
    // return the state actor. Mirrors what MCPClaudeConfigWriter.writeAndRegister
    // does internally without touching ~/.sonata/mcp-cfg on disk.
    @discardableResult
    func registerSession(
        sessionKey: String, role: SessionRole = .worker
    ) async -> (token: String, state: MCPSessionState) {
        let token = MCPTokenGenerator.newToken()
        await mcpRegistry.registerToken(
            sessionKey: sessionKey, token: token, role: role)
        let state = await mcpRegistry.getOrCreate(sessionKey) { role }
        return (token, state)
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
