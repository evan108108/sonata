import XCTest
import GRDB
@testable import Sonata

// worker_set_status(clearCurrentEvent) on a still-'assigned' event (idea from
// daily learnings 11/19, learning 634c9156).
//
// THE INCIDENT: Scout unwedged worker-1698379606 on 11/16 by clearing its
// pointer. The held event was still 'assigned', which means the session's model
// loop was stuck, but its bridge kept heartbeating. The clear set it idle, so it
// was routable: the Verona Carpenter task reached it 10s later and the 7200s
// watchdog killed that task at 120 min.
//
// Every test drives the real MCP tools/call path, so the action's wiring is
// exercised along with applySetWorkerStatus.
final class ClearCurrentEventDrainTests: XCTestCase {

    private func insertWorker(_ h: MCPTestHarness, id: String, status: String, currentEventId: String?) async throws {
        let now = nowMs()
        try await h.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO workers (workerId, sessionLabel, status, lastHeartbeat, registeredAt, currentEventId)
                VALUES (?, 'sona-worker-9', ?, ?, ?, ?)
            """, arguments: [id, status, now, now, currentEventId])
        }
    }

    private func insertEvent(_ h: MCPTestHarness, id: String, status: String, assignedTo: String) async throws {
        let now = nowMs()
        try await h.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, priority, status, assignedTo, createdAt, assignedAt)
                VALUES (?, 'task', '{}', 5, ?, ?, ?, ?)
            """, arguments: [id, status, assignedTo, now, now])
        }
    }

    private func workerRow(_ h: MCPTestHarness, _ id: String) async throws -> (status: String?, currentEventId: String?) {
        try await h.dbPool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT status, currentEventId FROM workers WHERE workerId = ?", arguments: [id])
            return (row?["status"], row?["currentEventId"])
        }
    }

    private func eventRow(_ h: MCPTestHarness, _ id: String) async throws -> (status: String?, result: String?) {
        try await h.dbPool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT status, result FROM workerEvents WHERE id = ?", arguments: [id])
            return (row?["status"], row?["result"])
        }
    }

    /// Call a tool and return its decoded JSON body.
    private func call(_ h: MCPTestHarness, _ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        let raw = await h.handle(
            sessionKey: "supervisor-test", role: .worker,
            method: "tools/call", id: 1,
            params: ["name": name, "arguments": args])
        let response = try XCTUnwrap(raw).data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let result = try XCTUnwrap(response?["result"] as? [String: Any], "no result in \(raw ?? "nil")")
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(name) errored: \(result)")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "\(name) body is not a JSON object: \(text)")
    }

    private func clear(_ h: MCPTestHarness, worker: String, expected: String?, force: Bool = false) async throws -> [String: Any] {
        var args: [String: Any] = ["workerId": worker, "status": "idle", "clearCurrentEvent": true]
        if let expected { args["expectedEventId"] = expected }
        if force { args["force"] = true }
        return try await call(h, "worker_set_status", args)
    }

    /// The fix. A held event still 'assigned' to this worker means live work is
    /// being abandoned: the event closes and the worker is left draining, and a
    /// heartbeat afterwards leaves it draining. Fails without the branch, which
    /// sets idle.
    func testAssignedHeldEventLeavesWorkerDraining() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await insertWorker(h, id: "W_WEDGED", status: "busy", currentEventId: "E_LIVE")
        try await insertEvent(h, id: "E_LIVE", status: "assigned", assignedTo: "W_WEDGED")

        let body = try await clear(h, worker: "W_WEDGED", expected: "E_LIVE")

        XCTAssertEqual(body["success"] as? Bool, true)
        XCTAssertEqual(body["drainedInstead"] as? Bool, true, "response must say it drained instead: \(body)")
        XCTAssertEqual(body["status"] as? String, "draining")
        XCTAssertEqual(body["closedEventId"] as? String, "E_LIVE")
        XCTAssertTrue((body["message"] as? String ?? "").contains("worker_cycle"), "message must point at worker_cycle: \(body)")

        let w = try await workerRow(h, "W_WEDGED")
        XCTAssertEqual(w.status, "draining", "a worker that held live work must not be routable")
        XCTAssertNil(w.currentEventId)
        let e = try await eventRow(h, "E_LIVE")
        XCTAssertEqual(e.status, "completed", "the abandoned event is still closed, as before")
        XCTAssertEqual(e.result, "closed via worker_set_status(clearCurrentEvent)")

        // The bridge keeps heartbeating a wedged session; draining must survive it.
        _ = try await call(h, "worker_heartbeat", ["workerId": "W_WEDGED"])
        let after = try await workerRow(h, "W_WEDGED")
        XCTAssertEqual(after.status, "draining", "a heartbeat must not put the wedged worker back in the pool")
    }

    /// The legitimate use: a stale pointer to an already-terminal event (after a
    /// complete_event no-op or a dm_reply). Today's behaviour holds: idle, and
    /// the terminal event is not re-mutated.
    func testTerminalHeldEventSetsRequestedStatus() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await insertWorker(h, id: "W_STALE", status: "busy", currentEventId: "E_DONE")
        try await insertEvent(h, id: "E_DONE", status: "completed", assignedTo: "W_STALE")

        let body = try await clear(h, worker: "W_STALE", expected: "E_DONE")

        XCTAssertEqual(body["success"] as? Bool, true)
        XCTAssertNil(body["drainedInstead"], "a stale pointer is not live work: \(body)")
        let w = try await workerRow(h, "W_STALE")
        XCTAssertEqual(w.status, "idle")
        XCTAssertNil(w.currentEventId)
        let e = try await eventRow(h, "E_DONE")
        XCTAssertEqual(e.status, "completed")
        XCTAssertNil(e.result, "a terminal event must not be re-closed")
    }

    /// A pointer to an event row that no longer exists is stale too.
    func testMissingHeldEventSetsRequestedStatus() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await insertWorker(h, id: "W_GHOST", status: "busy", currentEventId: "E_GONE")

        let body = try await clear(h, worker: "W_GHOST", expected: "E_GONE")

        XCTAssertNil(body["drainedInstead"])
        let w = try await workerRow(h, "W_GHOST")
        XCTAssertEqual(w.status, "idle")
        XCTAssertNil(w.currentEventId)
    }

    /// An event still 'assigned' but to a DIFFERENT worker is a genuine
    /// re-dispatch; this worker's pointer is stale. Not closed, not drained.
    func testEventAssignedElsewhereIsAStalePointer() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await insertWorker(h, id: "W_OLD", status: "busy", currentEventId: "E_MOVED")
        try await insertEvent(h, id: "E_MOVED", status: "assigned", assignedTo: "W_NEW")

        let body = try await clear(h, worker: "W_OLD", expected: "E_MOVED")

        XCTAssertNil(body["drainedInstead"])
        let w = try await workerRow(h, "W_OLD")
        let e = try await eventRow(h, "E_MOVED")
        XCTAssertEqual(w.status, "idle")
        XCTAssertEqual(e.status, "assigned", "the new owner's live event must not be closed")
    }

    /// `force` bypasses only the CAS. An unguarded clear of live work still drains.
    func testForceDoesNotBypassTheDrain() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await insertWorker(h, id: "W_FORCED", status: "busy", currentEventId: "E_LIVE2")
        try await insertEvent(h, id: "E_LIVE2", status: "assigned", assignedTo: "W_FORCED")

        let body = try await clear(h, worker: "W_FORCED", expected: nil, force: true)

        XCTAssertEqual(body["drainedInstead"] as? Bool, true, "force must not reopen the routable-wedge path: \(body)")
        let w = try await workerRow(h, "W_FORCED")
        let e = try await eventRow(h, "E_LIVE2")
        XCTAssertEqual(w.status, "draining")
        XCTAssertEqual(e.status, "completed")
    }
}
