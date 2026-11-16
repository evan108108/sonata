import XCTest
import GRDB
@testable import Sonata

/// The health monitor's "busy but idle" nudge must reach only the session
/// that holds the event (WorkerNudgeGate). Replays the 11/16 sequence
/// (memory 80943708): event 58227180 was assigned to an old worker row whose
/// session never received the push; the registry then re-registered, the
/// event went to sona-worker-2, and the "sona-worker-8" label moved to a new
/// workerId. The old session got 5 nudges. It must get 0.
///
/// Every fixture carries a control worker that genuinely holds an event and
/// has been idle past the threshold. It must get exactly 1 nudge, so a 0 for
/// the old session can't come from a sweep that sends nothing at all.
final class WorkerNudgeHolderTests: XCTestCase {

    // Ids copied from the 11/16 incident rows.
    let eventId = "58227180dad6495b9ce458a225f0a45b"
    let oldWorker = "worker-7141959727", oldSession = "ea5b1c11-9ae4-4d62-a07e-c0a7b43098c5"
    let newHolder = "worker-7843867451", newHolderSession = "173c543d-06c0-4167-9e2e-dabfe4fef936"
    let relabeled = "worker-8378438706", relabeledSession = "f8a98ce3-1b01-4a24-bbd1-3fe72fff256e"

    let ctrlWorker = "worker-ctrl", ctrlSession = "ctrl-session-0001", ctrlEvent = "evt-ctrl-0001"

    let min: Int64 = 60_000

    private func insertWorker(_ db: Database, id: String, label: String, session: String,
                              status: String, event: String?, heartbeat: Int64,
                              progress: Int64?, registeredAt: Int64) throws {
        try db.execute(sql: """
            INSERT INTO workers (workerId, sessionLabel, sessionId, status, currentEventId,
                                 lastHeartbeat, lastProgressAt, registeredAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, label, session, status, event, heartbeat, progress, registeredAt])
    }

    private func insertEvent(_ db: Database, id: String, assignedTo: String,
                             session: String, assignedAt: Int64) throws {
        try db.execute(sql: """
            INSERT INTO workerEvents (id, type, payload, priority, status, assignedTo,
                                      sessionId, createdAt, assignedAt)
            VALUES (?, 'task', '{}', 5, 'assigned', ?, ?, ?, ?)
            """, arguments: [id, assignedTo, session, assignedAt, assignedAt])
    }

    /// Control: holds its event, took a model turn after assignment, quiet
    /// for 60 min (past the 45-min threshold), heartbeat fresh.
    private func insertControl(_ db: Database, now: Int64) throws {
        try insertEvent(db, id: ctrlEvent, assignedTo: ctrlWorker,
                        session: ctrlSession, assignedAt: now - 120 * min)
        try insertWorker(db, id: ctrlWorker, label: "sona-worker-3", session: ctrlSession,
                         status: "busy", event: ctrlEvent, heartbeat: now,
                         progress: now - 60 * min, registeredAt: now - 180 * min)
    }

    private func nudges(_ pool: DatabasePool, to session: String) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM dm_messages
                WHERE fromSessionId = 'sonata-health-monitor' AND targetSessionId = ?
                """, arguments: [session]) ?? -1
        }
    }

    private func totalNudges(_ pool: DatabasePool) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM dm_messages WHERE fromSessionId = 'sonata-health-monitor'
                """) ?? -1
        }
    }

    /// After the reset: the old row still points at the event, but the event
    /// is held by sona-worker-2 and the label belongs to a new workerId.
    func test_replay_afterReassignAndReregister_oldSessionGetsZero() async throws {
        let pool = try MCPTestHarness.make().dbPool
        let now = nowMs()
        try await pool.write { db in
            // Reassigned: event now held by sona-worker-2.
            try self.insertEvent(db, id: self.eventId, assignedTo: self.newHolder,
                                 session: self.newHolderSession, assignedAt: now - 2 * self.min)
            // Old row survives with a stale currentEventId, stale progress.
            try self.insertWorker(db, id: self.oldWorker, label: "sona-worker-8", session: self.oldSession,
                                  status: "busy", event: self.eventId, heartbeat: now,
                                  progress: now - 60 * self.min, registeredAt: now - 600 * self.min)
            // New holder, actively working.
            try self.insertWorker(db, id: self.newHolder, label: "sona-worker-2", session: self.newHolderSession,
                                  status: "busy", event: self.eventId, heartbeat: now,
                                  progress: now - 1 * self.min, registeredAt: now - 2 * self.min)
            // Label "sona-worker-8" re-registered under a new workerId, idle.
            try self.insertWorker(db, id: self.relabeled, label: "sona-worker-8", session: self.relabeledSession,
                                  status: "idle", event: nil, heartbeat: now,
                                  progress: nil, registeredAt: now - 2 * self.min)
            try self.insertControl(db, now: now)
        }

        let h = HealthMonitor(dbPool: pool)
        await h.nudgeStuckWorkersForTesting()

        let toOld = try await nudges(pool, to: oldSession)
        let toHolder = try await nudges(pool, to: newHolderSession)
        let toRelabeled = try await nudges(pool, to: relabeledSession)
        let toCtrl = try await nudges(pool, to: ctrlSession)
        XCTAssertEqual(toOld, 0, "old session must get 0 nudges for an event another worker holds")
        XCTAssertEqual(toHolder, 0, "the real holder is making progress; no nudge")
        XCTAssertEqual(toRelabeled, 0, "a reused label must never inherit a nudge")
        XCTAssertEqual(toCtrl, 1, "control: a genuine idle holder still gets exactly 1 nudge")
        let total = try await totalNudges(pool)
        XCTAssertEqual(total, 1)
    }

    /// Before the reset, at the moment of the real nudges: the event is
    /// assigned to the old worker, but that session took no model turn since
    /// the hand-off (its push was never delivered). Flag as stranded, don't nudge.
    func test_replay_assignedButNeverDelivered_isStrandedNotNudged() async throws {
        let pool = try MCPTestHarness.make().dbPool
        let now = nowMs()
        try await pool.write { db in
            try self.insertEvent(db, id: self.eventId, assignedTo: self.oldWorker,
                                 session: self.oldSession, assignedAt: now - 2 * self.min)
            try self.insertWorker(db, id: self.oldWorker, label: "sona-worker-8", session: self.oldSession,
                                  status: "busy", event: self.eventId, heartbeat: now,
                                  progress: now - 60 * self.min, registeredAt: now - 600 * self.min)
            try self.insertControl(db, now: now)
        }

        let h = HealthMonitor(dbPool: pool)
        let outcome = await h.gateAndPersistNudge(
            workerId: oldWorker, eventId: eventId,
            aliveSinceMs: now - 90_000, stuckBeforeMs: now - 45 * min)
        guard case .decided(.possiblyStranded(let s, _, _)) = outcome else {
            return XCTFail("expected possiblyStranded, got \(outcome)")
        }
        XCTAssertEqual(s, oldSession)

        await h.nudgeStuckWorkersForTesting()
        let toOld = try await nudges(pool, to: oldSession)
        let toCtrl = try await nudges(pool, to: ctrlSession)
        XCTAssertEqual(toOld, 0, "a never-delivered event must not produce a complete_event nudge")
        XCTAssertEqual(toCtrl, 1, "control still gets exactly 1")
    }

    /// The reassignment lands between the sweep's read and the send. The
    /// gate re-reads inside the insert's transaction and refuses.
    func test_reassignmentAfterSweepRead_gateRefuses() async throws {
        let pool = try MCPTestHarness.make().dbPool
        let now = nowMs()
        try await pool.write { db in
            try self.insertEvent(db, id: self.eventId, assignedTo: self.oldWorker,
                                 session: self.oldSession, assignedAt: now - 120 * self.min)
            try self.insertWorker(db, id: self.oldWorker, label: "sona-worker-8", session: self.oldSession,
                                  status: "busy", event: self.eventId, heartbeat: now,
                                  progress: now - 60 * self.min, registeredAt: now - 600 * self.min)
        }
        // The sweep would have selected oldWorker here. Now reassign.
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE workerEvents SET assignedTo = ?, sessionId = ?, assignedAt = ? WHERE id = ?
                """, arguments: [self.newHolder, self.newHolderSession, now, self.eventId])
        }
        let h = HealthMonitor(dbPool: pool)
        let outcome = await h.gateAndPersistNudge(
            workerId: oldWorker, eventId: eventId,
            aliveSinceMs: now - 90_000, stuckBeforeMs: now - 45 * min)
        guard case .decided(.skip(.reassigned(let holder))) = outcome else {
            return XCTFail("expected skip(.reassigned), got \(outcome)")
        }
        XCTAssertEqual(holder, newHolder)
        let total = try await totalNudges(pool)
        XCTAssertEqual(total, 0)
    }

    /// Control alone across two sweeps: exactly 1 nudge (cooldown), routed
    /// to the event's sessionId, naming the workerId.
    func test_control_genuineHolder_getsExactlyOneNudge() async throws {
        let pool = try MCPTestHarness.make().dbPool
        let now = nowMs()
        try await pool.write { db in try self.insertControl(db, now: now) }

        let h = HealthMonitor(dbPool: pool)
        await h.nudgeStuckWorkersForTesting()
        await h.nudgeStuckWorkersForTesting()

        let toCtrl = try await nudges(pool, to: ctrlSession)
        XCTAssertEqual(toCtrl, 1)
        let body: String? = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM dm_messages WHERE targetSessionId = ?",
                                arguments: [self.ctrlSession])
        }
        XCTAssertEqual(body?.contains("worker \(ctrlWorker)"), true)
        XCTAssertEqual(body?.contains(ctrlEvent), true)
    }

    // MARK: - Pure gate

    func test_gate_sessionMismatch_skips() {
        let w = WorkerNudgeGate.WorkerSnapshot(
            workerId: "w1", sessionId: "s-new", sessionLabel: "sona-worker-1", status: "busy",
            currentEventId: "e1", lastHeartbeat: 1_000, lastProgressAt: 50)
        let e = WorkerNudgeGate.EventSnapshot(
            id: "e1", status: "assigned", assignedTo: "w1", assignedAt: 10, sessionId: "s-old")
        XCTAssertEqual(
            WorkerNudgeGate.decide(eventId: "e1", worker: w, event: e, aliveSinceMs: 900, stuckBeforeMs: 100),
            .skip(.sessionMismatch(workerSession: "s-new", eventSession: "s-old")))
    }

    func test_gate_completedEvent_skips() {
        let w = WorkerNudgeGate.WorkerSnapshot(
            workerId: "w1", sessionId: "s1", sessionLabel: "sona-worker-1", status: "busy",
            currentEventId: "e1", lastHeartbeat: 1_000, lastProgressAt: 50)
        let e = WorkerNudgeGate.EventSnapshot(
            id: "e1", status: "completed", assignedTo: "w1", assignedAt: 10, sessionId: "s1")
        XCTAssertEqual(
            WorkerNudgeGate.decide(eventId: "e1", worker: w, event: e, aliveSinceMs: 900, stuckBeforeMs: 100),
            .skip(.eventNotAssigned(status: "completed")))
    }
}
