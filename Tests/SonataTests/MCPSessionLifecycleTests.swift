import XCTest
import GRDB
import Logging
@testable import Sonata

// Plan §9 test 4 — Session lifecycle: getOrCreate, evict, snapshot,
// rotateToken, sweeper start/stop. Covers the eviction path the DELETE
// endpoint hits and the sweeper liveness wiring without paying for an
// HTTP server boot.

final class MCPSessionLifecycleTests: XCTestCase {

    func testGetOrCreateCachesSessionState() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        var roleCallCount = 0
        let key = "worker-cache"
        await h.mcpRegistry.registerToken(
            sessionKey: key, token: "t", role: .worker)

        let first = await h.mcpRegistry.getOrCreate(key) {
            roleCallCount += 1
            return .worker
        }
        let second = await h.mcpRegistry.getOrCreate(key) {
            roleCallCount += 1
            return .worker
        }
        // Both calls return state but inferRole only runs when the state
        // doesn't exist yet (registerToken already created it above).
        let firstKey = await first.sessionKey
        let secondKey = await second.sessionKey
        XCTAssertEqual(firstKey, key)
        XCTAssertEqual(secondKey, key)
        XCTAssertEqual(roleCallCount, 0,
            "registerToken should have pre-created the state, so inferRole never runs")
    }

    func testEvictRemovesSessionAndClosesWriter() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "worker-ev1", role: .worker)
        let writer = MCPSSEWriter()
        await state.attachSSE(writer)

        XCTAssertFalse(writer.isClosed)
        await h.mcpRegistry.evict("worker-ev1")
        XCTAssertTrue(writer.isClosed, "evict must close the attached writer")

        let goneState = await h.mcpRegistry.get("worker-ev1")
        XCTAssertNil(goneState, "evicted session must be removed from the registry map")

        // Token entry also goes; subsequent validateBearer rejects.
        let stillValid = await h.mcpRegistry.validateBearer(
            sessionKey: "worker-ev1", suppliedToken: "anything")
        XCTAssertFalse(stillValid)
    }

    func testRotateTokenInvalidatesOldToken() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (oldToken, _) = await h.registerSession(sessionKey: "worker-rot", role: .worker)
        let newToken = await h.mcpRegistry.rotateToken(sessionKey: "worker-rot")
        XCTAssertNotEqual(oldToken, newToken)

        let newOK = await h.mcpRegistry.validateBearer(
            sessionKey: "worker-rot", suppliedToken: newToken)
        let oldOK = await h.mcpRegistry.validateBearer(
            sessionKey: "worker-rot", suppliedToken: oldToken)
        XCTAssertTrue(newOK)
        XCTAssertFalse(oldOK, "old token must be rejected after rotation")
    }

    func testSnapshotReportsActiveSessionsWithSSEFlag() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, stateA) = await h.registerSession(sessionKey: "snap-a", role: .worker)
        _ = await h.registerSession(sessionKey: "snap-b", role: .supervisor)

        let writerA = MCPSSEWriter()
        await stateA.attachSSE(writerA)

        let snaps = await h.mcpRegistry.snapshot()
        XCTAssertEqual(snaps.count, 2)
        let byKey = Dictionary(uniqueKeysWithValues: snaps.map { ($0.sessionKey, $0) })
        XCTAssertEqual(byKey["snap-a"]?.role, .worker)
        XCTAssertEqual(byKey["snap-a"]?.hasSSE, true)
        XCTAssertEqual(byKey["snap-b"]?.role, .supervisor)
        XCTAssertEqual(byKey["snap-b"]?.hasSSE, false)
    }

    func testSweeperStartTickStop() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        // A worker row already exists in the DB; sweeper's tick will update
        // its lastHeartbeat when the session has SSE attached.
        let now = nowMs()
        try await h.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO workers
                    (workerId, sessionLabel, status, lastHeartbeat, registeredAt)
                VALUES ('worker-sw1', 'sona-worker-1', 'idle', ?, ?)
            """, arguments: [now - 60_000, now - 60_000])
        }

        let (_, state) = await h.registerSession(sessionKey: "worker-sw1", role: .worker)
        let writer = MCPSSEWriter()
        await state.attachSSE(writer)
        await state.touch()

        let sweeper = MCPSessionSweeper(
            registry: h.mcpRegistry,
            dbPool: h.dbPool,
            logger: Logger(label: "test.sweeper"))
        await sweeper.start()
        // Sweeper ticks every 15s; the test doesn't wait that long.
        // Instead we verify the registry tickKeepAlives is callable
        // without crashing and snapshot mirrors what tick would observe.
        await h.mcpRegistry.tickKeepAlives()
        let snaps = await h.mcpRegistry.snapshot()
        XCTAssertTrue(snaps.contains { $0.sessionKey == "worker-sw1" && $0.hasSSE })
        await sweeper.stop()
    }

    // MARK: - Webview session driver (Phase 1)

    @MainActor
    func testWebviewCreateListCloseLifecycle() async throws {
        let svc = WebviewSessionService.shared
        let before = svc.list().count
        let sid = svc.create(ownerAgentId: "worker-a", url: nil, partition: "t-create", background: true)
        XCTAssertTrue(svc.list().contains { $0.sessionId == sid && $0.background && $0.ownerAgentId == "worker-a" })
        // Background ⇒ created suspended (no WKWebView built).
        XCTAssertEqual(svc.list().first { $0.sessionId == sid }?.status, "suspended")
        try svc.close(sessionId: sid)
        XCTAssertEqual(svc.list().count, before)
    }

    @MainActor
    func testFocusResumesSuspendedSession() async throws {
        let svc = WebviewSessionService.shared
        let sid = svc.create(ownerAgentId: "worker-b", url: "about:blank", partition: "t-focus", background: true)
        defer { try? svc.close(sessionId: sid) }
        XCTAssertEqual(svc.list().first { $0.sessionId == sid }?.status, "suspended")
        try svc.focus(sessionId: sid)
        XCTAssertEqual(svc.list().first { $0.sessionId == sid }?.status, "live")
    }

    @MainActor
    func testCloseOwnedByAutoClosesAgentSessions() async throws {
        let vm = InteractiveSessionsViewModel.shared
        let svc = WebviewSessionService.shared
        let s1 = svc.create(ownerAgentId: "worker-die", url: nil, partition: "t-d1", background: true)
        let s2 = svc.create(ownerAgentId: "worker-die", url: nil, partition: "t-d2", background: true)
        let other = svc.create(ownerAgentId: "worker-live", url: nil, partition: "t-d3", background: true)
        defer { try? svc.close(sessionId: other) }
        vm.closeOwnedBy(agentId: "worker-die")
        let ids = svc.list().map(\.sessionId)
        XCTAssertFalse(ids.contains(s1)); XCTAssertFalse(ids.contains(s2))
        XCTAssertTrue(ids.contains(other), "other agent's session must survive")
    }
}
