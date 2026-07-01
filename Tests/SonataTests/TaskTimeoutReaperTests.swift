import XCTest
import GRDB
@testable import Sonata

/// Tests for `HealthMonitor.reapOverdueTasks()` — the deterministic wall-clock
/// timeout reaper that replaced supervisor-session-dependent kill enforcement.
///
/// Background (Scout nightly-watchdog escalation, 2026-07-01, mem 22c69d6a):
/// `metadata.timeoutSeconds` used to be enforced ONLY by a live `/supervisor`
/// LLM session. On nights with no session running, tasks overran for hours and
/// were then batch-killed at once with inconsistent, hand-composed error text
/// ("Exceeded 75-minute timeout" instead of a timeoutSeconds-aware string), and
/// the pool worker each overdue task occupied stayed busy the whole time —
/// which is what tripped the "pool below target" alert. The reaper enforces the
/// deadline deterministically every monitor cycle: fail the task with one
/// consistent message AND recycle the pool worker holding it.
final class TaskTimeoutReaperTests: XCTestCase {

    /// An active task past its `timeoutSeconds` deadline is failed with the
    /// consistent message, its dispatch event is terminated, and the pool
    /// worker holding it is freed to idle so the slot recovers.
    func test_overdueTask_isFailedAndWorkerRecycled() async throws {
        let pool = try MCPTestHarness.make().dbPool
        let now = nowMs()
        let taskId = "task-overdue-1"
        let eventId = "evt-overdue-1"
        let workerId = "worker-overdue-1"
        // started 200 min ago with a 120-min (7200s) deadline → 80 min overdue.
        let startedAt = now - 200 * 60_000
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, title, status, source, startedAt, metadata, createdAt, updatedAt)
                VALUES (?, 'Nightly scout: overdue', 'active', 'test', ?, '{"timeoutSeconds":7200}', ?, ?)
            """, arguments: [taskId, startedAt, now, now])
            try db.execute(sql: """
                INSERT INTO workers (workerId, sessionLabel, status, lastHeartbeat, registeredAt, currentEventId)
                VALUES (?, 'sona-worker-1', 'busy', ?, ?, ?)
            """, arguments: [workerId, now, now, eventId])
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, priority, status, assignedTo, createdAt, assignedAt)
                VALUES (?, 'task', ?, 5, 'assigned', ?, ?, ?)
            """, arguments: [eventId, "{\"task_id\":\"\(taskId)\"}", workerId, now, now])
        }

        let h = HealthMonitor(dbPool: pool)
        await h.reapOverdueTasksForTesting()

        let (status, lastError): (String?, String?) = try await pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT status, lastError FROM tasks WHERE id = ?", arguments: [taskId])
            return (row?["status"], row?["lastError"])
        }
        XCTAssertEqual(status, "failed", "overdue task must be failed")
        XCTAssertEqual(lastError?.contains("timeoutSeconds:7200"), true,
            "kill message must cite timeoutSeconds, never a stale '75-minute' string")
        XCTAssertEqual(lastError?.contains("deterministic watchdog"), true,
            "kill message must be the single consistent watchdog string")

        let eventStatus: String? = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM workerEvents WHERE id = ?", arguments: [eventId])
        }
        XCTAssertEqual(eventStatus, "failed", "the dispatch event must be terminated")

        let (wStatus, wEvent): (String?, String?) = try await pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT status, currentEventId FROM workers WHERE workerId = ?", arguments: [workerId])
            return (row?["status"], row?["currentEventId"])
        }
        XCTAssertEqual(wStatus, "idle", "the pool worker must be freed so the slot recovers")
        XCTAssertNil(wEvent, "the freed worker must no longer hold the event")
    }

    /// A task still within its deadline is left running untouched.
    func test_taskWithinDeadline_isUntouched() async throws {
        let pool = try MCPTestHarness.make().dbPool
        let now = nowMs()
        let taskId = "task-fresh-1"
        // started 10 min ago with a 120-min deadline → not overdue.
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, title, status, source, startedAt, metadata, createdAt, updatedAt)
                VALUES (?, 'Nightly scout: fresh', 'active', 'test', ?, '{"timeoutSeconds":7200}', ?, ?)
            """, arguments: [taskId, now - 10 * 60_000, now, now])
        }
        let h = HealthMonitor(dbPool: pool)
        await h.reapOverdueTasksForTesting()
        let status: String? = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM tasks WHERE id = ?", arguments: [taskId])
        }
        XCTAssertEqual(status, "active", "a task within its deadline must not be reaped")
    }

    /// A long-running active task with NO `timeoutSeconds` is never reaped —
    /// the wall-clock deadline is opt-in; absence means "no limit".
    func test_taskWithoutTimeout_isNeverReaped() async throws {
        let pool = try MCPTestHarness.make().dbPool
        let now = nowMs()
        let taskId = "task-notimeout-1"
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, title, status, source, startedAt, metadata, createdAt, updatedAt)
                VALUES (?, 'long task, no deadline', 'active', 'test', ?, '{"foo":"bar"}', ?, ?)
            """, arguments: [taskId, now - 10_000 * 60_000, now, now])
        }
        let h = HealthMonitor(dbPool: pool)
        await h.reapOverdueTasksForTesting()
        let status: String? = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM tasks WHERE id = ?", arguments: [taskId])
        }
        XCTAssertEqual(status, "active", "no timeoutSeconds → no wall-clock kill")
    }
}
