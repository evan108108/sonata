import XCTest
import GRDB
@testable import Sonata

// EFB-48 — parallel dispatches from one session clobbering each other's
// checkpoints.
//
// THE INCIDENT (2026-07-31, reproduced by four workers across four batches):
// one session dispatched three workers inside 87 seconds and saved a
// checkpoint for each. Every worker that called mem_checkpoint_restore got the
// *newest* of the three — so two of the three workers restored a stranger's
// task brief and started work against it. A worker that scoped the restore to
// its own id fared worse: owning no checkpoint of its own, it fell through to
// the pre-v31 NULL-sessionId bucket and was handed the supervisor's state.
//
// THE REFRAME THESE TESTS PIN: storage was never the problem. SQLite kept all
// three rows, correctly, with the right session ids and timestamps. The bug was
// that the read API's only key was "newest row," so the other two rows were
// unreachable by any caller. The fix is a retrieval key, not a write path —
// hence every test here is a read test against rows that all committed fine.
//
// Written to FAIL against the pre-fix behavior: `testRestoreBySessionRefuses…`
// and `testTiebreak…` both pass trivially under the old code only if you delete
// the assertion, and the legacy-fallback pair demonstrates the old shape really
// does hand back a foreign checkpoint.
final class CheckpointParallelDispatchTests: XCTestCase {

    // MARK: - Fixture

    /// Real schema via the production bootstrap, so this fixture cannot drift
    /// away from what the handlers actually run against.
    private func makeDbPool() throws -> DatabasePool {
        let tmp = NSTemporaryDirectory() + "sonata-checkpoint-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        try pool.write { db in try ensureCheckpointTablesForAction(db) }
        return pool
    }

    @discardableResult
    private func save(
        _ pool: DatabasePool,
        id: String,
        state: String,
        sessionId: String?,
        createdAt: Int64
    ) throws -> String {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO checkpoints (id, state, skills, project, createdAt, sessionId)
                VALUES (?, ?, NULL, NULL, ?, ?)
                """,
                arguments: [id, state, createdAt, sessionId]
            )
        }
        return id
    }

    private func fetch(_ pool: DatabasePool, _ lookup: CheckpointLookup) throws -> CheckpointRow? {
        try pool.read { db in try fetchCheckpoint(db, lookup) }
    }

    /// The incident, exactly: three dispatches, one session, seconds apart.
    private func seedThreeParallelDispatches(_ pool: DatabasePool) throws {
        let sona = "f4e8ed22-897d-418a-a96d-1ebe6fa340e4"
        try save(pool, id: "ckpt-efb54", state: "EFB-54 dispatch", sessionId: sona, createdAt: 1_785_529_983_866)
        try save(pool, id: "ckpt-efb48", state: "EFB-48 dispatch", sessionId: sona, createdAt: 1_785_530_029_646)
        try save(pool, id: "ckpt-efb30", state: "EFB-30 dispatch", sessionId: sona, createdAt: 1_785_530_070_042)
    }

    // MARK: - The missing retrieval key

    func testEachParallelDispatchIsReachableByItsOwnId() throws {
        let pool = try makeDbPool()
        try seedThreeParallelDispatches(pool)

        // The whole point: all three dispatches addressable, not just the last.
        for (id, expected) in [
            ("ckpt-efb54", "EFB-54 dispatch"),
            ("ckpt-efb48", "EFB-48 dispatch"),
            ("ckpt-efb30", "EFB-30 dispatch"),
        ] {
            let row = try fetch(pool, .byId(id))
            XCTAssertEqual(row?.state, expected, "\(id) must resolve to its own checkpoint")
        }
    }

    func testRestoreByIdNeverFallsBack() throws {
        let pool = try makeDbPool()
        try seedThreeParallelDispatches(pool)
        try save(pool, id: "ckpt-legacy", state: "supervisor state", sessionId: nil, createdAt: 1_785_530_099_999)

        // A miss must be a miss. If byId ever fell back, it would hand back the
        // newest row — which is precisely the failure being fixed.
        XCTAssertNil(
            try fetch(pool, .byId("ckpt-does-not-exist")),
            "byId must return nothing rather than substitute another checkpoint"
        )
    }

    func testUnscopedRestoreStillReturnsGlobalNewest() throws {
        // Regression guard: the pre-scoping behavior is unchanged for callers
        // that pass no key at all.
        let pool = try makeDbPool()
        try seedThreeParallelDispatches(pool)
        XCTAssertEqual(try fetch(pool, .latest)?.state, "EFB-30 dispatch")
    }

    // MARK: - Rider A: no silent wrong-fallback

    func testRestoreBySessionRefusesToInheritLegacyCheckpoint() throws {
        let pool = try makeDbPool()
        // The NULL bucket, populated — 143 rows of it in the real database.
        try save(pool, id: "ckpt-supervisor", state: "SUPERVISOR SESSION", sessionId: nil, createdAt: 1_785_462_724_006)

        let row = try fetch(pool, .bySession("worker-5004200177", allowLegacyFallback: false))

        // Pre-fix this returned the supervisor's checkpoint, and the worker had
        // no way to know. A loud miss is the correct answer.
        XCTAssertNil(row, "a session with no checkpoint must not inherit the legacy bucket")
    }

    func testLegacyFallbackStillAvailableWhenExplicitlyRequested() throws {
        let pool = try makeDbPool()
        try save(pool, id: "ckpt-supervisor", state: "SUPERVISOR SESSION", sessionId: nil, createdAt: 1_785_462_724_006)

        // The escape hatch — and the demonstration that the old shape really
        // does hand back a foreign checkpoint, so the assertion above is not
        // certifying a behavior that was never possible.
        let row = try fetch(pool, .bySession("worker-5004200177", allowLegacyFallback: true))
        XCTAssertEqual(row?.state, "SUPERVISOR SESSION")
    }

    func testOwnCheckpointWinsOverLegacyBucket() throws {
        let pool = try makeDbPool()
        // Legacy row is NEWER — ordering must not let it outrank an owned row.
        try save(pool, id: "ckpt-mine", state: "my state", sessionId: "worker-1", createdAt: 1_000)
        try save(pool, id: "ckpt-legacy", state: "legacy state", sessionId: nil, createdAt: 9_999)

        for allow in [true, false] {
            let row = try fetch(pool, .bySession("worker-1", allowLegacyFallback: allow))
            XCTAssertEqual(row?.state, "my state", "own checkpoint must win (allowLegacyFallback: \(allow))")
        }
    }

    func testRestoreBySessionIgnoresOtherSessions() throws {
        let pool = try makeDbPool()
        try seedThreeParallelDispatches(pool)
        try save(pool, id: "ckpt-mine", state: "my state", sessionId: "worker-1", createdAt: 1_000)

        // Sona's rows are all newer; scoping must not leak them.
        XCTAssertEqual(try fetch(pool, .bySession("worker-1", allowLegacyFallback: false))?.state, "my state")
    }

    func testRestoreBySessionReturnsThatSessionsNewest() throws {
        let pool = try makeDbPool()
        try seedThreeParallelDispatches(pool)
        let row = try fetch(pool, .bySession("f4e8ed22-897d-418a-a96d-1ebe6fa340e4", allowLegacyFallback: false))
        XCTAssertEqual(row?.state, "EFB-30 dispatch", "session-scoped restore is still newest-wins")
    }

    // MARK: - Rider B: whose checkpoint is this?

    func testRestoreReportsOwningSession() throws {
        let pool = try makeDbPool()
        try seedThreeParallelDispatches(pool)

        // Turns content-verification discipline into a machine check.
        XCTAssertEqual(
            try fetch(pool, .byId("ckpt-efb48"))?.sessionId,
            "f4e8ed22-897d-418a-a96d-1ebe6fa340e4"
        )
    }

    func testLegacyCheckpointReportsNilSession() throws {
        let pool = try makeDbPool()
        try save(pool, id: "ckpt-legacy", state: "legacy", sessionId: nil, createdAt: 1)
        XCTAssertNil(try fetch(pool, .latest)?.sessionId)
    }

    // MARK: - Deterministic tiebreak

    func testSameMillisecondSavesResolveToTheLaterInsert() throws {
        let pool = try makeDbPool()
        let sona = "f4e8ed22-897d-418a-a96d-1ebe6fa340e4"
        // A tight dispatch burst can land two saves in the same millisecond.
        // Without the rowid tiebreak, which one wins is undefined.
        try save(pool, id: "ckpt-first", state: "first", sessionId: sona, createdAt: 5_000)
        try save(pool, id: "ckpt-second", state: "second", sessionId: sona, createdAt: 5_000)

        XCTAssertEqual(try fetch(pool, .bySession(sona, allowLegacyFallback: false))?.state, "second")
        XCTAssertEqual(try fetch(pool, .latest)?.state, "second")
    }

    func testTiebreakIsStableAcrossRepeatedReads() throws {
        let pool = try makeDbPool()
        let sona = "s1"
        try save(pool, id: "a", state: "a", sessionId: sona, createdAt: 7)
        try save(pool, id: "b", state: "b", sessionId: sona, createdAt: 7)
        try save(pool, id: "c", state: "c", sessionId: sona, createdAt: 7)

        let reads = try (0..<8).map { _ in try fetch(pool, .bySession(sona, allowLegacyFallback: false))?.state }
        XCTAssertEqual(Set(reads), ["c"], "repeated reads must not oscillate between same-ms rows")
    }

    // MARK: - Lookup precedence

    func testCheckpointIdWinsOverSessionId() throws {
        // An exact key must never be weakened by a coarser one — a dispatcher
        // handing out a checkpoint id shouldn't have to also clear sessionId.
        XCTAssertEqual(
            resolveCheckpointLookup(checkpointId: "ckpt-1", sessionId: "worker-1", allowLegacyFallback: false),
            .byId("ckpt-1")
        )
    }

    func testBlankStringsAreTreatedAsAbsent() throws {
        // MCP callers routinely send "" for an unset optional. Treating that as
        // a real key would make every such call a guaranteed not-found.
        XCTAssertEqual(
            resolveCheckpointLookup(checkpointId: "", sessionId: "worker-1", allowLegacyFallback: false),
            .bySession("worker-1", allowLegacyFallback: false)
        )
        XCTAssertEqual(
            resolveCheckpointLookup(checkpointId: "", sessionId: "", allowLegacyFallback: false),
            .latest
        )
        XCTAssertEqual(
            resolveCheckpointLookup(checkpointId: nil, sessionId: nil, allowLegacyFallback: false),
            .latest
        )
    }

    func testFallbackFlagRidesOnTheSessionLookup() throws {
        XCTAssertEqual(
            resolveCheckpointLookup(checkpointId: nil, sessionId: "w1", allowLegacyFallback: true),
            .bySession("w1", allowLegacyFallback: true)
        )
    }

    // MARK: - End-to-end incident replay

    func testThreeParallelDispatchesEachRestoreTheirOwnBrief() throws {
        let pool = try makeDbPool()
        try seedThreeParallelDispatches(pool)
        try save(pool, id: "ckpt-supervisor", state: "SUPERVISOR SESSION", sessionId: nil, createdAt: 1_785_462_724_006)

        // Each worker is handed its checkpoint id at dispatch time.
        let dispatched = [
            ("worker-a", "ckpt-efb54", "EFB-54 dispatch"),
            ("worker-b", "ckpt-efb48", "EFB-48 dispatch"),
            ("worker-c", "ckpt-efb30", "EFB-30 dispatch"),
        ]
        for (worker, ckptId, expected) in dispatched {
            let row = try fetch(pool, .byId(ckptId))
            XCTAssertEqual(row?.state, expected, "\(worker) restored the wrong brief")
        }

        // And the old path a worker would otherwise take now fails loud
        // instead of quietly yielding the supervisor's state.
        XCTAssertNil(try fetch(pool, .bySession("worker-b", allowLegacyFallback: false)))
    }
}
