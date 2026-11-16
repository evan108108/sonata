import XCTest
import GRDB
@testable import Sonata

/// Poisoned idle worker (2026-11-16, scout-cloud). Event 44bd0a33 was
/// cancelled 11/14 08:57Z without clearing worker-6400434031's currentEventId.
/// The row stayed `idle` with the freshest heartbeat, so findIdleWorker picked
/// it on every poll and the claim UPDATE (which requires an empty
/// currentEventId) refused it every time: 138,126 "no longer idle at claim
/// time" lines, and nightly dispatch stalled ~2 days with other workers idle.
///
/// Every "skipped" assertion is paired with a control that the other worker
/// WAS chosen, or that the row is otherwise eligible, so a predicate that
/// matches nothing can't pass.
final class PoisonedIdleWorkerTests: XCTestCase {

    private let poisoned = "worker-6400434031"
    private let clean = "worker-2222222222"
    private let deadEvent = "evt-cancelled-44bd0a33"

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func addWorker(_ pool: DatabasePool, id: String, label: String, status: String = "idle",
                           currentEventId: String? = nil, heartbeat: Int64 = nowMs()) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workers (workerId, sessionLabel, status, lastHeartbeat, registeredAt, currentEventId)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [id, label, status, heartbeat, heartbeat, currentEventId])
        }
    }

    private func addEvent(_ pool: DatabasePool, id: String, status: String, assignedTo: String) async throws {
        let now = nowMs()
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, priority, status, assignedTo, createdAt, assignedAt)
                VALUES (?, 'task', '{"task_id":"t-old"}', 5, ?, ?, ?, ?)
            """, arguments: [id, status, assignedTo, now, now])
        }
    }

    private func addTask(_ pool: DatabasePool, id: String, ageMs: Int64, assignedTo: String? = "scheduler") async throws {
        let created = nowMs() - ageMs
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, title, prompt, status, source, assignedTo, createdAt, updatedAt)
                VALUES (?, 'Nightly scout: test', 'do it', 'pending', 'scheduler', ?, ?, ?)
            """, arguments: [id, assignedTo, created, created])
        }
    }

    private func currentEvent(_ pool: DatabasePool, _ worker: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT currentEventId FROM workers WHERE workerId = ?", arguments: [worker])
        }
    }

    /// The scout-cloud shape: poisoned row has the fresher heartbeat.
    private func addPoisonedAndClean(_ pool: DatabasePool) async throws {
        try await addEvent(pool, id: deadEvent, status: "cancelled", assignedTo: poisoned)
        try await addWorker(pool, id: clean, label: "sona-worker-2", heartbeat: nowMs() - 5_000)
        try await addWorker(pool, id: poisoned, label: "sona-worker-3", currentEventId: deadEvent)
    }

    // MARK: - findIdleWorker / dispatchToChannel

    func testFindIdleWorkerSkipsIdleRowStillHoldingAnEvent() async throws {
        let pool = try makePool()
        try await addPoisonedAndClean(pool)
        let picked = await SonataChannelServer(dbPool: pool).findIdleWorker()
        XCTAssertEqual(picked, clean, "the fresher poisoned row must be skipped for the claimable one")
    }

    func testOnlyPoisonedWorkerMeansNoWorker() async throws {
        let pool = try makePool()
        try await addEvent(pool, id: deadEvent, status: "cancelled", assignedTo: poisoned)
        try await addWorker(pool, id: poisoned, label: "sona-worker-3", currentEventId: deadEvent)
        let server = SonataChannelServer(dbPool: pool)
        let none = await server.findIdleWorker()
        XCTAssertNil(none)
        // Control: the same row with its pointer cleared is eligible.
        try await pool.write { db in try db.execute(sql: "UPDATE workers SET currentEventId = NULL") }
        let freed = await server.findIdleWorker()
        XCTAssertEqual(freed, poisoned)
    }

    func testDispatchLandsOnClaimableWorker() async throws {
        let pool = try makePool()
        try await addPoisonedAndClean(pool)
        let eventId = await SonataChannelServer(dbPool: pool).dispatchToChannel(
            taskId: "t-new", title: "Nightly scout: p57", prompt: "go", dispatchCycle: "1")
        XCTAssertNotNil(eventId, "dispatch must succeed while a claimable worker is idle")
        let assignedTo: String? = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT assignedTo FROM workerEvents WHERE id = ?", arguments: [eventId])
        }
        XCTAssertEqual(assignedTo, clean)
    }

    func testSkipWorkerIdsNarrowSearchButStayOutOfPayload() async throws {
        let pool = try makePool()
        try await addWorker(pool, id: clean, label: "sona-worker-2", heartbeat: nowMs() - 5_000)
        try await addWorker(pool, id: poisoned, label: "sona-worker-3")
        let eventId = await SonataChannelServer(dbPool: pool).dispatchToChannel(
            taskId: "t-new", title: "t", prompt: "go", dispatchCycle: "1", skipWorkerIds: [poisoned])
        let (assignedTo, payload): (String?, String) = try await pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT assignedTo, payload FROM workerEvents WHERE id = ?", arguments: [eventId])
            return (row?["assignedTo"], row?["payload"] ?? "")
        }
        XCTAssertEqual(assignedTo, clean, "a skipped (fresher) worker must not be chosen")
        XCTAssertFalse(payload.contains(DispatchExclusion.eventPayloadKey),
                       "retry skips are per-call and must not persist as a dispatch exclusion")
    }

    // MARK: - releaseIdleWorkersHoldingDeadEvents

    func testReleaseClearsTerminalAndMissingButKeepsLiveAndBusy() async throws {
        let pool = try makePool()
        try await addEvent(pool, id: deadEvent, status: "cancelled", assignedTo: poisoned)
        try await addEvent(pool, id: "evt-live", status: "assigned", assignedTo: "worker-afk")
        try await addEvent(pool, id: "evt-done", status: "completed", assignedTo: "worker-busy")
        try await addWorker(pool, id: poisoned, label: "sona-worker-3", currentEventId: deadEvent)
        try await addWorker(pool, id: "worker-missing", label: "sona-worker-4", currentEventId: "evt-gone")
        try await addWorker(pool, id: "worker-afk", label: "sona-worker-5", currentEventId: "evt-live")
        try await addWorker(pool, id: "worker-busy", label: "sona-worker-6", status: "busy", currentEventId: "evt-done")

        await HealthMonitor(dbPool: pool).releaseIdleWorkersHoldingDeadEventsForTesting()

        let poisonedAfter = try await currentEvent(pool, poisoned)
        let missingAfter = try await currentEvent(pool, "worker-missing")
        XCTAssertNil(poisonedAfter, "idle + cancelled event → cleared")
        XCTAssertNil(missingAfter, "idle + nonexistent event → cleared")
        let afkAfter = try await currentEvent(pool, "worker-afk")
        let busyAfter = try await currentEvent(pool, "worker-busy")
        XCTAssertEqual(afkAfter, "evt-live", "idle with a still-open event (AFK/DM wait) is left alone")
        XCTAssertEqual(busyAfter, "evt-done", "busy rows belong to the stuck-worker path, not this sweep")
        let picked = await SonataChannelServer(dbPool: pool).findIdleWorker()
        XCTAssertNotNil(picked, "after release the freed workers are dispatchable again")
    }

    // MARK: - checkDispatchStall

    func testStallFlagsOldDispatchableTaskWithFreeWorker() async throws {
        let pool = try makePool()
        try await addWorker(pool, id: clean, label: "sona-worker-2")
        try await addTask(pool, id: "t-stuck", ageMs: HealthMonitor.dispatchStallThresholdMs + 60_000)
        let r = await HealthMonitor(dbPool: pool).checkDispatchStallForTesting()
        XCTAssertFalse(r.healthy)
        XCTAssertTrue(r.message.contains("t-stuck"), "the message names the oldest waiting task")
    }

    func testStallQuietForYoungTaskOtherAssigneeOrNoFreeWorker() async throws {
        let pool = try makePool()
        try await addWorker(pool, id: clean, label: "sona-worker-2")
        try await addTask(pool, id: "t-young", ageMs: 60_000)
        try await addTask(pool, id: "t-owned", ageMs: HealthMonitor.dispatchStallThresholdMs + 60_000, assignedTo: "someone-else")
        let h = HealthMonitor(dbPool: pool)
        let quiet = await h.checkDispatchStallForTesting()
        XCTAssertTrue(quiet.healthy, "young or non-scheduler tasks are normal queueing")

        // Control: an old scheduler task flips it, so the quiet result above
        // isn't a query that matches nothing.
        try await addTask(pool, id: "t-old", ageMs: HealthMonitor.dispatchStallThresholdMs + 60_000)
        let flagged = await h.checkDispatchStallForTesting()
        XCTAssertFalse(flagged.healthy)

        // Same backlog with every worker busy is backpressure, not a stall.
        try await pool.write { db in try db.execute(sql: "UPDATE workers SET status = 'busy'") }
        let busy = await h.checkDispatchStallForTesting()
        XCTAssertTrue(busy.healthy)
    }
}
