import XCTest
import GRDB
@testable import Sonata

// Tests for the task-watch / task-unwatch primitive (push-vs-poll).
// Plan: STATUS 6 thread, task 16a9e85a — Evan dispatch 2026-05-17.

final class TaskWatcherTests: XCTestCase {

    // MARK: - In-memory harness

    private func makeTestDbPool() throws -> DatabasePool {
        let tmp = NSTemporaryDirectory() + "sonata-taskwatch-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        try pool.write { db in
            // Minimal tasks slice — only the columns the watcher actions touch.
            try db.execute(sql: """
                CREATE TABLE tasks (
                    id          TEXT PRIMARY KEY,
                    title       TEXT NOT NULL,
                    status      TEXT NOT NULL,
                    createdAt   INTEGER NOT NULL,
                    updatedAt   INTEGER NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE task_watchers (
                    taskId            TEXT NOT NULL,
                    target_session_id TEXT NOT NULL,
                    on_mask           TEXT NOT NULL,
                    createdAt         INTEGER NOT NULL,
                    PRIMARY KEY (taskId, target_session_id)
                )
            """)
            try db.execute(sql: """
                CREATE INDEX task_watchers_by_task ON task_watchers(taskId)
            """)
            // dm_messages — written by the production dispatcher when not
            // overridden. Most of these tests inject a capture dispatcher
            // and don't read this table, but the schema needs to exist.
            try db.execute(sql: """
                CREATE TABLE dm_messages (
                    messageId        TEXT PRIMARY KEY,
                    targetSessionId  TEXT NOT NULL,
                    fromSessionId    TEXT,
                    fromPubkey       TEXT,
                    fromPeerId       TEXT,
                    body             TEXT NOT NULL,
                    context          TEXT,
                    metaJson         TEXT,
                    sentAtMs         INTEGER NOT NULL,
                    receivedAtMs     INTEGER NOT NULL,
                    deliveredAtMs    INTEGER,
                    deliveryStatus   TEXT NOT NULL
                )
            """)
        }
        return pool
    }

    private func insertTask(_ pool: DatabasePool, id: String, status: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO tasks (id, title, status, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, "test-\(id)", status, now, now]
            )
        }
    }

    private func insertWatcher(
        _ pool: DatabasePool,
        taskId: String,
        target: String,
        on: [String] = ["status_change"]
    ) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let json = try String(data: JSONEncoder().encode(on), encoding: .utf8) ?? "[]"
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO task_watchers (taskId, target_session_id, on_mask, createdAt)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [taskId, target, json, now]
            )
        }
    }

    private func watcherCount(_ pool: DatabasePool, taskId: String) throws -> Int {
        try pool.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM task_watchers WHERE taskId = ?",
                arguments: [taskId]
            ) ?? 0
        }
    }

    // MARK: - Capturing dispatcher

    actor DispatchCapture {
        struct Call: Equatable {
            let target: String
            let body: String
            let context: String
        }
        private(set) var calls: [Call] = []
        func record(target: String, body: String, context: String) {
            calls.append(Call(target: target, body: body, context: context))
        }
        func snapshot() -> [Call] { calls }
    }

    private func makeCaptureDispatcher(_ capture: DispatchCapture) -> TaskWatcherDispatcher {
        TaskWatcherDispatcher(send: { target, body, context, _ in
            await capture.record(target: target, body: body, context: context)
            return true
        })
    }

    // MARK: - Tests

    /// Acceptance #1: register one watcher, transition the task, assert the
    /// dispatcher was called with the right payload.
    func testSingleWatcherFiresOnTransition() async throws {
        let pool = try makeTestDbPool()
        try insertTask(pool, id: "T1", status: "pending")
        try insertWatcher(pool, taskId: "T1", target: "claude-A")

        let capture = DispatchCapture()
        let liveness = TaskWatcherLiveness(lastContactedAtMs: { _ in
            Int64(Date().timeIntervalSince1970 * 1000)  // fresh
        })

        let fired = await fireTaskWatcherDMs(
            taskId: "T1", oldStatus: "pending", newStatus: "completed",
            dbPool: pool, liveness: liveness,
            dispatcher: makeCaptureDispatcher(capture)
        )

        XCTAssertEqual(fired, 1)
        let calls = await capture.snapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].target, "claude-A")
        XCTAssertEqual(calls[0].context, "task_watch")
        // Payload should be JSON with our four fields.
        let data = calls[0].body.data(using: .utf8) ?? Data()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["taskId"] as? String, "T1")
        XCTAssertEqual(json?["oldStatus"] as? String, "pending")
        XCTAssertEqual(json?["newStatus"] as? String, "completed")
        XCTAssertNotNil(json?["ts"])
    }

    /// Acceptance #2: two watchers on the same task, one transition fires
    /// both.
    func testTwoWatchersBothFireOnOneTransition() async throws {
        let pool = try makeTestDbPool()
        try insertTask(pool, id: "T2", status: "active")
        try insertWatcher(pool, taskId: "T2", target: "claude-A")
        try insertWatcher(pool, taskId: "T2", target: "claude-B")

        let capture = DispatchCapture()
        let liveness = TaskWatcherLiveness(lastContactedAtMs: { _ in
            Int64(Date().timeIntervalSince1970 * 1000)
        })

        let fired = await fireTaskWatcherDMs(
            taskId: "T2", oldStatus: "active", newStatus: "completed",
            dbPool: pool, liveness: liveness,
            dispatcher: makeCaptureDispatcher(capture)
        )

        XCTAssertEqual(fired, 2)
        let calls = await capture.snapshot()
        XCTAssertEqual(calls.count, 2)
        let targets = Set(calls.map { $0.target })
        XCTAssertEqual(targets, ["claude-A", "claude-B"])
    }

    /// Acceptance #3: one watcher's session is dead (no registry entry,
    /// or contact timestamp past the 15-min cutoff). On the next transition
    /// the dead row is swept and only the live watcher fires.
    func testDeadWatcherIsSweptAndLiveOneFires() async throws {
        let pool = try makeTestDbPool()
        try insertTask(pool, id: "T3", status: "active")
        try insertWatcher(pool, taskId: "T3", target: "live-session")
        try insertWatcher(pool, taskId: "T3", target: "dead-session")
        XCTAssertEqual(try watcherCount(pool, taskId: "T3"), 2)

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let staleCutoff = now - (taskWatcherStaleAfterMs + 1_000)
        let liveness = TaskWatcherLiveness(lastContactedAtMs: { sessionId in
            switch sessionId {
            case "live-session": return now
            case "dead-session": return staleCutoff  // past the 15-min cutoff
            default: return nil
            }
        })

        let capture = DispatchCapture()
        let fired = await fireTaskWatcherDMs(
            taskId: "T3", oldStatus: "active", newStatus: "completed",
            dbPool: pool, liveness: liveness,
            dispatcher: makeCaptureDispatcher(capture)
        )

        XCTAssertEqual(fired, 1, "only the live session should be DM'd")
        let calls = await capture.snapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].target, "live-session")

        // Dead watcher row should be gone; live watcher row should remain.
        XCTAssertEqual(try watcherCount(pool, taskId: "T3"), 1)
        let remaining = try await pool.read { db -> String? in
            try String.fetchOne(
                db,
                sql: "SELECT target_session_id FROM task_watchers WHERE taskId = ?",
                arguments: ["T3"]
            )
        }
        XCTAssertEqual(remaining, "live-session")
    }

    /// Watcher with on_mask=[done] only fires on terminal-success
    /// transitions, not on intermediate ones.
    func testOnMaskFiltersTransitions() async throws {
        let pool = try makeTestDbPool()
        try insertTask(pool, id: "T4", status: "pending")
        try insertWatcher(pool, taskId: "T4", target: "claude-A", on: ["done"])

        let liveness = TaskWatcherLiveness(lastContactedAtMs: { _ in
            Int64(Date().timeIntervalSince1970 * 1000)
        })

        // pending → active: should NOT fire (mask is "done").
        let capture1 = DispatchCapture()
        let firedA = await fireTaskWatcherDMs(
            taskId: "T4", oldStatus: "pending", newStatus: "active",
            dbPool: pool, liveness: liveness,
            dispatcher: makeCaptureDispatcher(capture1)
        )
        XCTAssertEqual(firedA, 0)
        let callsA = await capture1.snapshot()
        XCTAssertEqual(callsA.count, 0)

        // active → completed: should fire.
        let capture2 = DispatchCapture()
        let firedB = await fireTaskWatcherDMs(
            taskId: "T4", oldStatus: "active", newStatus: "completed",
            dbPool: pool, liveness: liveness,
            dispatcher: makeCaptureDispatcher(capture2)
        )
        XCTAssertEqual(firedB, 1)
    }

    /// No-op when oldStatus == newStatus (e.g. /complete on an
    /// already-completed task).
    func testNoOpWhenStatusUnchanged() async throws {
        let pool = try makeTestDbPool()
        try insertTask(pool, id: "T5", status: "completed")
        try insertWatcher(pool, taskId: "T5", target: "claude-A")

        let liveness = TaskWatcherLiveness(lastContactedAtMs: { _ in
            Int64(Date().timeIntervalSince1970 * 1000)
        })

        let capture = DispatchCapture()
        let fired = await fireTaskWatcherDMs(
            taskId: "T5", oldStatus: "completed", newStatus: "completed",
            dbPool: pool, liveness: liveness,
            dispatcher: makeCaptureDispatcher(capture)
        )
        XCTAssertEqual(fired, 0)
        let calls = await capture.snapshot()
        XCTAssertEqual(calls.count, 0)
    }
}
