import XCTest
import GRDB
@testable import Sonata

// worker_cycle (task 0d755b52, 11/19). Every test drives performWorkerCycle
// with a recording mock cycler. None may reach WorkerManager.shared or start
// the monitor loop: a real cycle SIGTERMs a live worker PTY, and the
// GhostWorkerReaper SIGTERMs any worker it doesn't own.
final class WorkerCycleActionTests: XCTestCase {

    /// Records which workerIds the action handed to the cycler.
    actor CyclerSpy {
        private(set) var calls: [String] = []
        func record(_ id: String) { calls.append(id) }
    }

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func insertWorker(_ pool: DatabasePool, id: String, currentEventId: String?) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO workers (workerId, sessionLabel, status, lastHeartbeat, registeredAt, sessionId, currentEventId)
                VALUES (?, 'sona-worker-9', ?, 1, 1, 'sess-1', ?)
            """, arguments: [id, currentEventId == nil ? "idle" : "busy", currentEventId])
        }
    }

    private func insertEvent(_ pool: DatabasePool, id: String, status: String, assignedTo: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, priority, status, assignedTo, createdAt)
                VALUES (?, 'task', '{}', 5, ?, ?, 1)
            """, arguments: [id, status, assignedTo])
        }
    }

    private func eventRow(_ pool: DatabasePool, _ id: String) throws -> (status: String?, assignedTo: String?) {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT status, assignedTo FROM workerEvents WHERE id = ?", arguments: [id])
            return (row?["status"], row?["assignedTo"])
        }
    }

    private func workerRow(_ pool: DatabasePool, _ id: String) throws -> (status: String?, currentEventId: String?) {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT status, currentEventId FROM workers WHERE workerId = ?", arguments: [id])
            return (row?["status"], row?["currentEventId"])
        }
    }

    private func cycler(_ spy: CyclerSpy, outcome: WorkerCycleOutcome) -> @Sendable (String) async -> WorkerCycleOutcome {
        { id in
            await spy.record(id)
            return outcome
        }
    }

    // MARK: - Refusal

    func testRefusesWith409WhileEventIsAssigned() async throws {
        let pool = try makePool()
        try insertWorker(pool, id: "w-1", currentEventId: "evt-old")
        try insertEvent(pool, id: "evt-old", status: "assigned", assignedTo: "w-1")
        let spy = CyclerSpy()

        do {
            _ = try await performWorkerCycle(workerId: "w-1", requeue: false, dbPool: pool,
                                             cycler: cycler(spy, outcome: .cycled(label: "sona-worker-9")))
            XCTFail("expected 409 while evt-old is assigned")
        } catch let ActionError.custom(msg, status) {
            XCTAssertEqual(status, .conflict)
            XCTAssertTrue(msg.contains("evt-old"), "error must name the held event: \(msg)")
            XCTAssertTrue(msg.contains("worker_event_fail"), "error must say how to settle it: \(msg)")
        }

        let calls = await spy.calls
        XCTAssertEqual(calls, [], "a refusal must not cycle")
        let evt = try eventRow(pool, "evt-old")
        XCTAssertEqual(evt.status, "assigned", "a refusal must leave the event alone")
        XCTAssertEqual(evt.assignedTo, "w-1")
        let w = try workerRow(pool, "w-1")
        XCTAssertEqual(w.currentEventId, "evt-old")
        XCTAssertEqual(w.status, "busy")
    }

    // MARK: - requeue=true

    func testRequeueRependsEventDrainsAndCycles() async throws {
        let pool = try makePool()
        try insertWorker(pool, id: "w-1", currentEventId: "evt-old")
        try insertEvent(pool, id: "evt-old", status: "assigned", assignedTo: "w-1")
        let spy = CyclerSpy()

        let resp = try await performWorkerCycle(workerId: "w-1", requeue: true, dbPool: pool,
                                                cycler: cycler(spy, outcome: .cycled(label: "sona-worker-9")))

        XCTAssertTrue(resp.cycled)
        XCTAssertEqual(resp.label, "sona-worker-9")
        XCTAssertNil(resp.skippedReason)
        XCTAssertEqual(resp.requeuedEventId, "evt-old")
        let calls = await spy.calls
        XCTAssertEqual(calls, ["w-1"])
        let evt = try eventRow(pool, "evt-old")
        XCTAssertEqual(evt.status, "pending", "requeue must re-pend the event like worker_drain")
        XCTAssertNil(evt.assignedTo)
        let w = try workerRow(pool, "w-1")
        XCTAssertNil(w.currentEventId)
        XCTAssertEqual(w.status, "draining", "the slot must not be routable before cycleWorker's drain lands")
    }

    // MARK: - Unknown worker

    func testUnknownWorkerIs404AndNotCycled() async throws {
        let pool = try makePool()
        let spy = CyclerSpy()

        do {
            _ = try await performWorkerCycle(workerId: "nobody", requeue: true, dbPool: pool,
                                             cycler: cycler(spy, outcome: .cycled(label: "x")))
            XCTFail("expected 404")
        } catch let error as ActionError {
            XCTAssertEqual(error.httpStatus, .notFound)
        }
        let calls = await spy.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: - Settled or idle workers pass through

    func testSettledEventDoesNotBlockAndIsNotRequeued() async throws {
        // The documented procedure: worker_event_fail first, then cycle. The
        // pointer can still name the now-failed event; that must not refuse.
        let pool = try makePool()
        try insertWorker(pool, id: "w-1", currentEventId: "evt-old")
        try insertEvent(pool, id: "evt-old", status: "failed", assignedTo: "w-1")
        let spy = CyclerSpy()

        let resp = try await performWorkerCycle(workerId: "w-1", requeue: false, dbPool: pool,
                                                cycler: cycler(spy, outcome: .cycled(label: "sona-worker-9")))

        XCTAssertTrue(resp.cycled)
        XCTAssertNil(resp.requeuedEventId)
        let calls = await spy.calls
        XCTAssertEqual(calls, ["w-1"])
        XCTAssertEqual(try eventRow(pool, "evt-old").status, "failed", "a settled event must stay settled")
    }

    func testSkippedOutcomeIsReported() async throws {
        let pool = try makePool()
        try insertWorker(pool, id: "w-1", currentEventId: nil)
        let spy = CyclerSpy()

        let resp = try await performWorkerCycle(workerId: "w-1", requeue: false, dbPool: pool,
                                                cycler: cycler(spy, outcome: .skipped(reason: "not tracked")))

        XCTAssertFalse(resp.cycled)
        XCTAssertNil(resp.label)
        XCTAssertEqual(resp.skippedReason, "not tracked")
        XCTAssertNil(resp.requeuedEventId)
    }

    // MARK: - Registration (no handler call: it would use the live cycler)

    func testActionIsRegisteredAsPostCycle() {
        let action = workerActions.first { $0.name == "worker_cycle" }
        XCTAssertNotNil(action)
        XCTAssertEqual(action?.group, "/api/worker")
        XCTAssertEqual(action?.path, "/cycle")
        XCTAssertEqual(action?.params.first { $0.name == "workerId" }?.required, true)
        XCTAssertEqual(action?.params.first { $0.name == "requeue" }?.required, false)
    }
}
