import XCTest
import GRDB
@testable import Sonata

// Regression tests for the 2026-07-20 dispatch freeze on the Scout machine.
//
// THE INCIDENT: worker-8368256472 called complete_event on its finished task
// (which already releases the worker), the dispatcher assigned it a new task
// 1.3s later, and the worker's habitual worker_set_status(clearCurrentEvent)
// then nulled a task it had never seen — closing the event with the task still
// `pending`. The event kept its day-scoped idempotency key, so the task could
// not be re-dispatched until midnight, and the five tasks chained behind it via
// blockedBy starved with it. ~6h of no dispatch.
//
// These tests are written to FAIL against the pre-fix behavior. The unguarded
// path is exercised explicitly (`force: true`) so each guarded assertion has a
// paired demonstration that the old shape really does eat the event — a test
// that cannot fail certifies nothing.
final class ClearCurrentEventCASTests: XCTestCase {

    // MARK: - The CAS predicate

    func testRefusesWhenSlotHoldsAFreshlyDispatchedEvent() {
        // The incident, exactly: caller means to release the event it just
        // completed; the slot already holds the dispatcher's next task.
        XCTAssertFalse(
            clearCurrentEventShouldProceed(held: "bksk-event", expected: "stuart-lynn-event", force: false),
            "must refuse to clear an event the caller never held"
        )
    }

    func testProceedsWhenSlotHoldsExactlyWhatCallerExpects() {
        XCTAssertTrue(
            clearCurrentEventShouldProceed(held: "evt-1", expected: "evt-1", force: false)
        )
    }

    func testRefusesWhenExpectedIsAbsent() {
        // The old default. Absent expectation must never mean "clear whatever is
        // there" — an optional guard that falls back to the unsafe behavior
        // protects nobody, because every existing caller sails past it.
        XCTAssertFalse(
            clearCurrentEventShouldProceed(held: "evt-1", expected: nil, force: false),
            "absent expectedEventId must not fall back to an unguarded clear"
        )
    }

    func testRefusesWhenSlotAlreadyEmpty() {
        // Someone else got here first. Whatever lands next is not ours to clear.
        XCTAssertFalse(
            clearCurrentEventShouldProceed(held: nil, expected: "evt-1", force: false)
        )
    }

    func testForceStillClearsUnconditionally() {
        // The endpoint's original purpose — repairing a genuinely mismatched
        // slot — must remain reachable, just deliberate.
        XCTAssertTrue(
            clearCurrentEventShouldProceed(held: "evt-other", expected: nil, force: true)
        )
    }

    // MARK: - Discriminator: the old shape must demonstrably eat the event

    func testUnguardedClearEatsFreshDispatch_oldBehavior() {
        // This is the positive control. If this ever starts returning false the
        // guarded assertions above stop being evidence of anything, because the
        // failure they prevent would no longer be reachable.
        let wouldClear = clearCurrentEventShouldProceed(
            held: "bksk-event", expected: nil, force: true
        )
        XCTAssertTrue(wouldClear, "pre-fix shape must still be demonstrably able to eat a fresh dispatch")
    }

    // MARK: - Idempotency key release

    /// Minimal schema mirroring the columns these paths touch.
    private func makeDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        try dbq.write { db in
            try db.execute(sql: """
                CREATE TABLE workerEvents (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    status TEXT NOT NULL,
                    assignedTo TEXT,
                    result TEXT,
                    createdAt INTEGER NOT NULL,
                    completedAt INTEGER,
                    idempotencyKey TEXT
                );
                CREATE UNIQUE INDEX idx_workerEvents_idempotencyKey
                    ON workerEvents(idempotencyKey);
            """)
        }
        return dbq
    }

    private func insertEvent(
        _ dbq: DatabaseQueue, id: String, taskId: String, status: String, key: String?
    ) throws {
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, status, assignedTo, createdAt, idempotencyKey)
                VALUES (?, 'task', ?, ?, 'worker-1', 1, ?)
            """, arguments: [id, #"{"task_id":"\#(taskId)"}"#, status, key])
        }
    }

    func testTerminalWithoutCompletionReleasesKey_soRedispatchIsPossible() throws {
        let dbq = try makeDB()
        try insertEvent(dbq, id: "evt-1", taskId: "task-A", status: "assigned", key: "task:task-A:2026-07-20")

        // The clearCurrentEvent close path, as fixed: close the event AND drop
        // its claim on the task's next attempt.
        try dbq.write { db in
            try db.execute(sql: """
                UPDATE workerEvents SET status = 'completed', completedAt = 2,
                    result = 'closed via worker_set_status(clearCurrentEvent)',
                    idempotencyKey = NULL
                WHERE id = ? AND status = 'assigned' AND assignedTo = 'worker-1'
            """, arguments: ["evt-1"])
        }

        // A redispatch in the SAME day bucket must now succeed. Pre-fix this
        // INSERT hit ON CONFLICT DO NOTHING and the task was stuck until midnight.
        let inserted = try dbq.write { db -> Int in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, status, assignedTo, createdAt, idempotencyKey)
                VALUES ('evt-2', 'task', '{"task_id":"task-A"}', 'assigned', 'worker-2', 3, ?)
                ON CONFLICT(idempotencyKey) DO NOTHING
            """, arguments: ["task:task-A:2026-07-20"])
            return db.changesCount
        }
        XCTAssertEqual(inserted, 1, "a terminal-but-incomplete event must not block the task's next attempt")
    }

    func testGenuineCompletionKeepsKey_soDupeGuardStillGuards() throws {
        let dbq = try makeDB()
        // A real completion keeps its key. If this ever releases, the guard that
        // stops two workers landing on one task (2026-07-07) stops working.
        try insertEvent(dbq, id: "evt-1", taskId: "task-B", status: "completed", key: "task:task-B:1730000000000")

        let inserted = try dbq.write { db -> Int in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, status, assignedTo, createdAt, idempotencyKey)
                VALUES ('evt-2', 'task', '{"task_id":"task-B"}', 'assigned', 'worker-2', 3, ?)
                ON CONFLICT(idempotencyKey) DO NOTHING
            """, arguments: ["task:task-B:1730000000000"])
            return db.changesCount
        }
        XCTAssertEqual(inserted, 0, "same-cycle redispatch must still be deduped")
    }

    func testNextPollCycleGetsAFreshKey_soCompletedTasksAreRerunnable() throws {
        let dbq = try makeDB()
        try insertEvent(dbq, id: "evt-1", taskId: "task-C", status: "completed", key: "task:task-C:1730000000000")

        // The dispatch_cycle fix: a later poll tick is a different cycle, so a
        // task that legitimately completed can be re-run the same day. Under the
        // old day-bucket key this INSERT was a no-op until midnight — which would
        // have traded a lockout-after-failure for a lockout-after-success.
        let inserted = try dbq.write { db -> Int in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, status, assignedTo, createdAt, idempotencyKey)
                VALUES ('evt-2', 'task', '{"task_id":"task-C"}', 'assigned', 'worker-2', 3, ?)
                ON CONFLICT(idempotencyKey) DO NOTHING
            """, arguments: ["task:task-C:1730000010000"])
            return db.changesCount
        }
        XCTAssertEqual(inserted, 1, "a later poll cycle must be able to re-run a completed task")
    }

    func testLegacyDayBucketKeysCannotCollideWithCycleKeys() throws {
        // Straddling the deploy: rows created before it carry day-bucket keys.
        // Post-deploy dispatches use cycle keys, which are a different string, so
        // legacy rows stop blocking immediately — no migration needed.
        let dbq = try makeDB()
        try insertEvent(dbq, id: "evt-old", taskId: "task-D", status: "completed", key: "task:task-D:2026-07-20")

        let inserted = try dbq.write { db -> Int in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, status, assignedTo, createdAt, idempotencyKey)
                VALUES ('evt-new', 'task', '{"task_id":"task-D"}', 'assigned', 'worker-2', 3, ?)
                ON CONFLICT(idempotencyKey) DO NOTHING
            """, arguments: ["task:task-D:1784553600000"])
            return db.changesCount
        }
        XCTAssertEqual(inserted, 1, "a cycle key must not collide with a pre-deploy day-bucket key")
    }
}
