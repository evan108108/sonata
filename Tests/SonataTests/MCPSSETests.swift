import XCTest
@testable import Sonata

// Plan §9 test 3 — SSE channel push round-trip.
//
// Also covers the dispatch-time G2 framing ("SSE p99 ≤5s in a 10-event
// burst") which Phase C cutover depends on: if a single session can't drain
// 10 channel pushes in 5s, the supervisor will miss `check` events under
// load, defeating the whole reason we moved off stdio.
//
// (Plan-document G2 — "Schema.applyMigrations and ActionRegistry.registerAll
// are the real entrypoint names" — is exercised implicitly by every test
// here, since MCPTestHarness boots the schema and registers actions. If
// either rename had been needed the harness wouldn't compile.)

final class MCPSSETests: XCTestCase {

    func testPushNotificationDeliversFrameToAttachedWriter() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "worker-sse1", role: .worker)
        let writer = MCPSSEWriter()
        await state.attachSSE(writer)

        let pushed = await h.mcpRegistry.pushNotification(
            sessionKey: "worker-sse1",
            method: "notifications/claude/channel",
            params: ["content": "hello-sse", "meta": ["event_type": "test"]]
        )
        XCTAssertTrue(pushed, "pushNotification must report true when the session has an attached writer")

        let frames = await MCPSSEFrameCollector.collect(
            from: writer, timeout: 2.0,
            until: { $0.contains("hello-sse") }
        )
        XCTAssertTrue(frames.contains { $0.contains("hello-sse") },
            "expected channel frame in SSE stream; got \(frames)")

        // Frame envelope shape is the JSON-RPC notification we promise to
        // Claude Code; assert all the load-bearing fields are present.
        let match = frames.first(where: { $0.contains("hello-sse") }) ?? ""
        let data = try XCTUnwrap(match.data(using: .utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["method"] as? String, "notifications/claude/channel")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["content"] as? String, "hello-sse")
    }

    func testPushReturnsFalseWhenNoSession() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let pushed = await h.mcpRegistry.pushNotification(
            sessionKey: "never-registered",
            method: "notifications/claude/channel",
            params: ["content": "lost", "meta": [:]]
        )
        XCTAssertFalse(pushed)
    }

    func testReconnectDetachesOldWriterFromNewPush() async throws {
        // Plan §10 R7 / §9 test 4 split: when a session re-opens its SSE
        // GET, the old writer is closed and only the new writer receives
        // subsequent pushes. Critical for survival of mac sleep / wake.
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "worker-rc1", role: .worker)
        let writer1 = MCPSSEWriter()
        await state.attachSSE(writer1)
        let writer2 = MCPSSEWriter()
        await state.attachSSE(writer2) // attachSSE closes writer1 internally

        XCTAssertTrue(writer1.isClosed, "first writer must be closed when second attaches")
        XCTAssertFalse(writer2.isClosed)

        _ = await h.mcpRegistry.pushNotification(
            sessionKey: "worker-rc1",
            method: "notifications/claude/channel",
            params: ["content": "second-only", "meta": [:]]
        )

        let framesOnNew = await MCPSSEFrameCollector.collect(
            from: writer2, timeout: 1.0,
            until: { $0.contains("second-only") }
        )
        XCTAssertTrue(framesOnNew.contains { $0.contains("second-only") },
            "new writer must receive the push; got \(framesOnNew)")
    }

    /// G2 (dispatch interpretation — SSE p99 ≤5s in a 10-event burst).
    /// Phase C cutover targets the supervisor, which receives `check` events
    /// roughly every 30s. If a 10-event burst can't drain in 5s in-process
    /// we'd be slower than the stdio bridge we're replacing, and the whole
    /// migration loses value.
    func testGate_G2_SSE_p99_under_5s_in_10event_burst() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "worker-burst", role: .worker)
        let writer = MCPSSEWriter()
        await state.attachSSE(writer)

        let burstCount = 10
        let start = Date()
        for i in 0..<burstCount {
            _ = await h.mcpRegistry.pushNotification(
                sessionKey: "worker-burst",
                method: "notifications/claude/channel",
                params: ["content": "burst-\(i)", "meta": ["seq": String(i)]]
            )
        }

        let frames = await MCPSSEFrameCollector.collect(
            from: writer, timeout: 5.0,
            until: { $0.contains("burst-9") }
        )
        let elapsed = Date().timeIntervalSince(start)
        let received = frames.filter { $0.contains("burst-") }
        XCTAssertEqual(received.count, burstCount,
            "all \(burstCount) frames must be delivered; got \(received.count) in \(elapsed)s")
        XCTAssertLessThan(elapsed, 5.0,
            "G2 violation: 10-event burst took \(elapsed)s, exceeds 5s budget")
    }
}
