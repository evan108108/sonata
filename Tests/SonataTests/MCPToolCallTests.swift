import XCTest
import GRDB
@testable import Sonata

// Plan §9 test 2 — Tools/call round-trip for complete_event + fail_event,
// plus the §12 G1 idempotency gate (R11 in §10).
//
// G1 is load-bearing because Phase B's MCPEventPusher.knownWorkerEventIds
// is an in-memory set that resets on every Sonata.app boot. When the app
// restarts, every still-pending row re-emits — and any worker that already
// completed mid-flight will receive a duplicate channel push and call
// complete_event a second time for the same event_id. If that second call
// errors, the worker's tool result reports failure and the worker may
// panic; if it succeeds, the rollback path is harmless. Both
// worker_event_complete and worker_event_fail must return success when
// called twice for the same event_id.

final class MCPToolCallTests: XCTestCase {

    func testCompleteEventTransitionsWorkerEventToCompleted() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        try await seedWorkerAndEvent(
            pool: h.dbPool, workerId: "worker-tc1", eventId: "evt-tc1")

        let (_, state) = await h.registerSession(sessionKey: "worker-tc1", role: .worker)
        let raw = await state.handle(
            method: "tools/call",
            id: 10,
            params: [
                "name": "complete_event",
                "arguments": ["event_id": "evt-tc1", "result": "ok"],
            ]
        )
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "tool call should succeed; got \(result)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")

        let status = try await h.dbPool.read { db in
            try String.fetchOne(db,
                sql: "SELECT status FROM workerEvents WHERE id = ?",
                arguments: ["evt-tc1"])
        }
        XCTAssertEqual(status, "completed")
    }

    func testFailEventTransitionsWorkerEventToFailed() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        try await seedWorkerAndEvent(
            pool: h.dbPool, workerId: "worker-tc2", eventId: "evt-tc2")

        let (_, state) = await h.registerSession(sessionKey: "worker-tc2", role: .worker)
        let raw = await state.handle(
            method: "tools/call",
            id: 11,
            params: [
                "name": "fail_event",
                "arguments": ["event_id": "evt-tc2", "error": "test failure"],
            ]
        )
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "tool call should succeed; got \(result)")

        let status = try await h.dbPool.read { db in
            try String.fetchOne(db,
                sql: "SELECT status FROM workerEvents WHERE id = ?",
                arguments: ["evt-tc2"])
        }
        XCTAssertEqual(status, "failed")
    }

    /// G1 (plan §10 R11). A duplicate complete_event call for an
    /// already-completed event must NOT report isError back to the worker.
    /// Today the underlying action returns success on a no-op; this test
    /// pins that contract so a regression would be caught pre-merge.
    func testGate_G1_CompleteEventIsIdempotent() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        try await seedWorkerAndEvent(
            pool: h.dbPool, workerId: "worker-g1a", eventId: "evt-g1a")
        let (_, state) = await h.registerSession(sessionKey: "worker-g1a", role: .worker)

        // First call — flips status to completed.
        _ = await state.handle(
            method: "tools/call", id: 100,
            params: [
                "name": "complete_event",
                "arguments": ["event_id": "evt-g1a", "result": "ok"],
            ])

        // Second call — same event_id, must succeed (no isError).
        let raw2 = await state.handle(
            method: "tools/call", id: 101,
            params: [
                "name": "complete_event",
                "arguments": ["event_id": "evt-g1a", "result": "ok"],
            ])
        let response2 = try parseJSON(raw2)
        let result2 = try XCTUnwrap(response2["result"] as? [String: Any])
        XCTAssertNil(result2["isError"],
            "G1 idempotency violation: duplicate complete_event reported isError. " +
            "Plan §10 R11 requires success. Result: \(result2)")

        // Status stays completed; the underlying row isn't double-mutated
        // into some weird state.
        let status = try await h.dbPool.read { db in
            try String.fetchOne(db,
                sql: "SELECT status FROM workerEvents WHERE id = ?",
                arguments: ["evt-g1a"])
        }
        XCTAssertEqual(status, "completed")
    }

    /// G1 sibling — fail_event must also be idempotent.
    func testGate_G1_FailEventIsIdempotent() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        try await seedWorkerAndEvent(
            pool: h.dbPool, workerId: "worker-g1b", eventId: "evt-g1b")
        let (_, state) = await h.registerSession(sessionKey: "worker-g1b", role: .worker)

        _ = await state.handle(
            method: "tools/call", id: 110,
            params: [
                "name": "fail_event",
                "arguments": ["event_id": "evt-g1b", "error": "boom"],
            ])
        let raw2 = await state.handle(
            method: "tools/call", id: 111,
            params: [
                "name": "fail_event",
                "arguments": ["event_id": "evt-g1b", "error": "boom"],
            ])
        let response2 = try parseJSON(raw2)
        let result2 = try XCTUnwrap(response2["result"] as? [String: Any])
        XCTAssertNil(result2["isError"],
            "G1 idempotency violation: duplicate fail_event reported isError. " +
            "Plan §10 R11 requires success. Result: \(result2)")

        let status = try await h.dbPool.read { db in
            try String.fetchOne(db,
                sql: "SELECT status FROM workerEvents WHERE id = ?",
                arguments: ["evt-g1b"])
        }
        XCTAssertEqual(status, "failed")
    }

    /// Workers can list tasks via mem_task_list. Pins the worker-allowlist
    /// wiring so a regression here surfaces immediately.
    func testMemTaskListReturnsRows() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        // Seed one pending row directly so the list call has something to return.
        let now = nowMs()
        try await h.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO tasks
                    (id, title, description, status, priority,
                     prompt, workingDir, model, maxTurns,
                     project, blockedBy, originalBlockedBy, parentTask,
                     source, sourceRef, tags, assignedTo, dueAt,
                     maxRetries, tools, metadata,
                     retryCount, outputFiles,
                     createdAt, updatedAt)
                VALUES (?, ?, NULL, 'pending', 'normal',
                        NULL, NULL, NULL, NULL,
                        NULL, '[]', '[]', NULL,
                        ?, NULL, '[]', NULL, NULL,
                        NULL, '[]', NULL,
                        0, '[]',
                        ?, ?)
            """, arguments: ["task-list-1", "seeded", "test", now, now])
        }

        let (_, state) = await h.registerSession(sessionKey: "worker-mtl", role: .worker)
        let raw = await state.handle(
            method: "tools/call", id: 200,
            params: ["name": "mem_task_list", "arguments": ["limit": 10]])
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "mem_task_list must succeed; got \(result)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("task-list-1"),
            "expected list to include seeded task; got: \(text)")
    }

    /// mem_task_create from a worker with no status must yield status='pending'.
    /// Anchors the pending-only invariant (feedback_mem_task_create_pending):
    /// the dispatcher only picks up pending rows, so active-on-create orphans.
    func testMemTaskCreateDefaultsToPending() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "worker-mtc1", role: .worker)
        let raw = await state.handle(
            method: "tools/call", id: 201,
            params: [
                "name": "mem_task_create",
                "arguments": [
                    "title": "from-worker",
                    "source": "test",
                ],
            ])
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "mem_task_create must succeed; got \(result)")

        let status = try await h.dbPool.read { db in
            try String.fetchOne(db,
                sql: "SELECT status FROM tasks WHERE title = ?",
                arguments: ["from-worker"])
        }
        XCTAssertEqual(status, "pending")
    }

    /// Worker-supplied status='active' must NOT survive — the handler
    /// silently coerces to 'pending' to avoid orphaning the task.
    func testMemTaskCreateCoercesActiveToPending() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "worker-mtc2", role: .worker)
        let raw = await state.handle(
            method: "tools/call", id: 202,
            params: [
                "name": "mem_task_create",
                "arguments": [
                    "title": "tried-active",
                    "source": "test",
                    "status": "active",
                ],
            ])
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(result["isError"],
            "mem_task_create must succeed even when caller asks for status=active; got \(result)")

        let status = try await h.dbPool.read { db in
            try String.fetchOne(db,
                sql: "SELECT status FROM tasks WHERE title = ?",
                arguments: ["tried-active"])
        }
        XCTAssertEqual(status, "pending",
            "worker-supplied status=active must be coerced to pending; got \(status ?? "nil")")
    }

    /// mem_task_get returns the row by ID.
    func testMemTaskGetReturnsRow() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let now = nowMs()
        try await h.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO tasks
                    (id, title, description, status, priority,
                     prompt, workingDir, model, maxTurns,
                     project, blockedBy, originalBlockedBy, parentTask,
                     source, sourceRef, tags, assignedTo, dueAt,
                     maxRetries, tools, metadata,
                     retryCount, outputFiles,
                     createdAt, updatedAt)
                VALUES (?, ?, NULL, 'pending', 'normal',
                        NULL, NULL, NULL, NULL,
                        NULL, '[]', '[]', NULL,
                        ?, NULL, '[]', NULL, NULL,
                        NULL, '[]', NULL,
                        0, '[]',
                        ?, ?)
            """, arguments: ["task-get-1", "fetchable", "test", now, now])
        }

        let (_, state) = await h.registerSession(sessionKey: "worker-mtg", role: .worker)
        let raw = await state.handle(
            method: "tools/call", id: 203,
            params: ["name": "mem_task_get", "arguments": ["id": "task-get-1"]])
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "mem_task_get must succeed; got \(result)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("fetchable"),
            "expected get result to include title; got: \(text)")
    }

    func testUnknownToolReturnsIsError() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "worker-unk", role: .worker)
        let raw = await state.handle(
            method: "tools/call", id: 12,
            params: ["name": "definitely_not_a_real_tool", "arguments": [:]])
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testUnknownMethodReturnsJSONRPCError() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "worker-mth", role: .worker)
        let raw = await state.handle(method: "does/not/exist", id: 13, params: [:])
        let response = try parseJSON(raw)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    // MARK: - shared helpers

    private func seedWorkerAndEvent(
        pool: DatabasePool, workerId: String, eventId: String
    ) async throws {
        let now = nowMs()
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workers
                    (workerId, sessionLabel, status, lastHeartbeat, registeredAt, currentEventId)
                VALUES (?, ?, 'busy', ?, ?, ?)
            """, arguments: [workerId, "sona-worker-1", now, now, eventId])
            try db.execute(sql: """
                INSERT INTO workerEvents
                    (id, type, payload, priority, status, assignedTo, createdAt, assignedAt)
                VALUES (?, 'task', '{}', 5, 'assigned', ?, ?, ?)
            """, arguments: [eventId, workerId, now, now])
        }
    }

    private func parseJSON(_ raw: String?) throws -> [String: Any] {
        let unwrapped = try XCTUnwrap(raw)
        let data = try XCTUnwrap(unwrapped.data(using: .utf8))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
