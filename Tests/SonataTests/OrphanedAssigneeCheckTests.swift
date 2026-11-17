import XCTest
import GRDB
@testable import Sonata

/// orphanedAssignee health check (2026-11-17). TaskDispatcher.poll() only
/// selects tasks whose assignedTo is 'scheduler', empty or NULL
/// (`TaskDispatcher.routableAssigneeSQL`). A task pinned to anything else, for
/// example a worker's sessionLabel `sona-worker-1` (7/30), is never polled and
/// never fails: it sits pending silently. dispatchStall can't see it, because
/// it only counts routable tasks.
///
/// Every quiet assertion is paired with a flagged control in the same DB, so a
/// predicate that matches nothing can't pass.
final class OrphanedAssigneeCheckTests: XCTestCase {

    private let old = HealthMonitor.orphanedAssigneeThresholdMs + 60_000

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func addWorker(_ pool: DatabasePool, id: String, label: String) async throws {
        let now = nowMs()
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workers (workerId, sessionLabel, status, lastHeartbeat, registeredAt)
                VALUES (?, ?, 'idle', ?, ?)
            """, arguments: [id, label, now, now])
        }
    }

    private func addTask(_ pool: DatabasePool, id: String, ageMs: Int64, assignedTo: String?,
                         blockedBy: String = "[]", parentTask: String? = nil) async throws {
        let created = nowMs() - ageMs
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, title, prompt, status, source, assignedTo, blockedBy, parentTask, createdAt, updatedAt)
                VALUES (?, 'pinned task', 'do it', 'pending', 'test', ?, ?, ?, ?, ?)
            """, arguments: [id, assignedTo, blockedBy, parentTask, created, created])
        }
    }

    /// The 7/30 shape: pinned to a worker's sessionLabel. A live worker
    /// carrying that label doesn't help, since only workerId counts.
    func testSessionLabelAssigneeTripsCheck() async throws {
        let pool = try makePool()
        try await addWorker(pool, id: "worker-1111111111", label: "sona-worker-1")
        try await addTask(pool, id: "t-pinned", ageMs: old, assignedTo: "sona-worker-1")
        let r = await HealthMonitor(dbPool: pool).checkOrphanedAssigneeForTesting()
        XCTAssertFalse(r.healthy, "a task pinned to a sessionLabel is never dispatched")
        XCTAssertEqual(r.name, "orphanedAssignee")
        XCTAssertTrue(r.message.contains("t-pinned"), "names the oldest task: \(r.message)")
        XCTAssertTrue(r.message.contains("assignedTo='sona-worker-1'"), "names its assignee: \(r.message)")
        XCTAssertTrue(r.message.contains("6h"), "names its age: \(r.message)")
    }

    func testSchedulerAssigneeDoesNotTripCheck() async throws {
        let pool = try makePool()
        try await addTask(pool, id: "t-sched", ageMs: old, assignedTo: "scheduler")
        try await addTask(pool, id: "t-empty", ageMs: old, assignedTo: "")
        try await addTask(pool, id: "t-null", ageMs: old, assignedTo: nil)
        let h = HealthMonitor(dbPool: pool)
        let quiet = await h.checkOrphanedAssigneeForTesting()
        XCTAssertTrue(quiet.healthy, "routable tasks are dispatchStall's concern: \(quiet.message)")

        // Control: the same DB flips once an unserved assignee appears.
        try await addTask(pool, id: "t-pinned", ageMs: old, assignedTo: "sona-worker-1")
        let flagged = await h.checkOrphanedAssigneeForTesting()
        XCTAssertFalse(flagged.healthy)
        XCTAssertTrue(flagged.message.hasPrefix("1 pending"), "only the pinned task counts: \(flagged.message)")
    }

    func testQuietForYoungBlockedContainerOrWorkerIdAssignee() async throws {
        let pool = try makePool()
        try await addWorker(pool, id: "worker-2222222222", label: "sona-worker-2")
        try await addTask(pool, id: "t-young", ageMs: 60_000, assignedTo: "orphan-test")
        try await addTask(pool, id: "t-blocked", ageMs: old, assignedTo: "orphan-test", blockedBy: "[\"t-young\"]")
        try await addTask(pool, id: "t-parent", ageMs: old, assignedTo: "orphan-test")
        try await addTask(pool, id: "t-child", ageMs: 60_000, assignedTo: "scheduler", parentTask: "t-parent")
        try await addTask(pool, id: "t-worker", ageMs: old, assignedTo: "worker-2222222222")
        let h = HealthMonitor(dbPool: pool)
        let quiet = await h.checkOrphanedAssigneeForTesting()
        XCTAssertTrue(quiet.healthy, "young, blocked, container and workerId-pinned tasks are excluded: \(quiet.message)")

        // Control: an old, unblocked leaf with the same assignee flips it.
        try await addTask(pool, id: "t-orphan", ageMs: old, assignedTo: "orphan-test")
        let flagged = await h.checkOrphanedAssigneeForTesting()
        XCTAssertFalse(flagged.healthy)
        XCTAssertTrue(flagged.message.contains("t-orphan"), flagged.message)
    }
}
