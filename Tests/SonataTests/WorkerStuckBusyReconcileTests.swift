import XCTest
import GRDB
@testable import Sonata

// Path #1 root-fix verification (recurring "worker stuck busy" class).
//
// The F4 owner-guard makes a stale complete_event a no-op for the EVENT/TASK
// side (correct — a zombie must not complete a re-dispatched task). But it also
// used to skip freeing the CALLING worker, leaving its currentEventId pinned and
// the worker `busy` forever. Nothing else recovered it: reclaimStrandedEvents
// only fires while the event is still 'assigned'; sweepOrphanedEvents only when
// the worker is gone. A live, fresh-heartbeat worker pinned to a *terminal*
// event fell through both and was hand-unstuck with worker_set_status.
//
// reconcilePinnedWorkers (called from the owner-guard reject branch of
// worker_event_complete / worker_event_fail) frees any worker still pinned to a
// non-live event, while leaving a genuine live re-dispatch's owner untouched.
// These tests drive the real MCP complete_event dispatch and assert the DB
// transition.
final class WorkerStuckBusyReconcileTests: XCTestCase {

    /// The fix. A worker calls complete_event for an event that is already
    /// terminal ('completed') and no longer owned by it. The owner-guard
    /// correctly skips the event/task side effects, AND the worker — left
    /// pinned to that terminal event — is freed back to the pool.
    func testStaleCompleteFreesWorkerPinnedToTerminalEvent() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let now = nowMs()
        try await h.dbPool.write { db in
            // W_STUCK is busy, still pinned to E_TERM.
            try db.execute(sql: """
                INSERT INTO workers
                    (workerId, sessionLabel, status, lastHeartbeat, registeredAt, currentEventId)
                VALUES ('W_STUCK', 'sona-worker-1', 'busy', ?, ?, 'E_TERM')
            """, arguments: [now, now])
            // E_TERM is already terminal and was reassigned away from W_STUCK.
            try db.execute(sql: """
                INSERT INTO workerEvents
                    (id, type, payload, priority, status, assignedTo, createdAt, assignedAt, completedAt)
                VALUES ('E_TERM', 'task', '{}', 5, 'completed', 'W_OTHER', ?, ?, ?)
            """, arguments: [now, now, now])
        }

        // W_STUCK completes the event it can no longer own.
        let raw = await h.handle(
            sessionKey: "W_STUCK", role: .worker,
            method: "tools/call", id: 1,
            params: [
                "name": "complete_event",
                "arguments": ["event_id": "E_TERM", "result": "stale zombie complete"],
            ])
        let response = try XCTUnwrap(raw).data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        // Idempotency preserved — no error surfaced to the worker.
        XCTAssertNotEqual(result["isError"] as? Bool, true, "stale complete must not error; got \(result)")

        let (workerStatus, pinnedEvent, eventStatus, eventOwner) = try await h.dbPool.read { db -> (String?, String?, String?, String?) in
            let ws = try Row.fetchOne(db, sql: "SELECT status, currentEventId FROM workers WHERE workerId = 'W_STUCK'")
            let es = try Row.fetchOne(db, sql: "SELECT status, assignedTo FROM workerEvents WHERE id = 'E_TERM'")
            return (ws?["status"], ws?["currentEventId"], es?["status"], es?["assignedTo"])
        }

        // THE FIX: W_STUCK is freed — idle, no pinned event.
        XCTAssertEqual(workerStatus, "idle", "stranded worker must be freed to idle")
        XCTAssertNil(pinnedEvent, "stranded worker's currentEventId must be cleared")
        // Owner-guard intact: the terminal event/owner is untouched.
        XCTAssertEqual(eventStatus, "completed", "the already-terminal event must not be re-mutated")
        XCTAssertEqual(eventOwner, "W_OTHER", "the event's owner must not be disturbed by a stale complete")
    }

    /// The guard. A zombie session completes an event that is still LIVE
    /// ('assigned') and legitimately owned by a DIFFERENT worker (a genuine
    /// re-dispatch). The reconcile must NOT free that owner — the event is live,
    /// so its owner is doing real work.
    func testStaleCompleteDoesNotFreeLiveReassignedOwner() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let now = nowMs()
        try await h.dbPool.write { db in
            // W_LEGIT legitimately owns the live event E_LIVE.
            try db.execute(sql: """
                INSERT INTO workers
                    (workerId, sessionLabel, status, lastHeartbeat, registeredAt, currentEventId)
                VALUES ('W_LEGIT', 'sona-worker-2', 'busy', ?, ?, 'E_LIVE')
            """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO workerEvents
                    (id, type, payload, priority, status, assignedTo, createdAt, assignedAt)
                VALUES ('E_LIVE', 'task', '{}', 5, 'assigned', 'W_LEGIT', ?, ?)
            """, arguments: [now, now])
        }

        // A zombie (not the owner) tries to complete the live event.
        let raw = await h.handle(
            sessionKey: "W_ZOMBIE", role: .worker,
            method: "tools/call", id: 2,
            params: [
                "name": "complete_event",
                "arguments": ["event_id": "E_LIVE", "result": "zombie complete of live event"],
            ])
        let response = try XCTUnwrap(raw).data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "zombie complete must not error; got \(result)")

        let (workerStatus, pinnedEvent, eventStatus) = try await h.dbPool.read { db -> (String?, String?, String?) in
            let ws = try Row.fetchOne(db, sql: "SELECT status, currentEventId FROM workers WHERE workerId = 'W_LEGIT'")
            let es = try String.fetchOne(db, sql: "SELECT status FROM workerEvents WHERE id = 'E_LIVE'")
            return (ws?["status"], ws?["currentEventId"], es)
        }

        // The live owner is left strictly alone.
        XCTAssertEqual(workerStatus, "busy", "the live event's owner must stay busy")
        XCTAssertEqual(pinnedEvent, "E_LIVE", "the live owner's currentEventId must be preserved")
        XCTAssertEqual(eventStatus, "assigned", "a live event must not be flipped by a zombie complete")
    }
}
