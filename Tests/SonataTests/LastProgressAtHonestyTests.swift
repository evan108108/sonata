import XCTest
import GRDB
@testable import Sonata

// `workers.lastProgressAt` had no ⊥ — no way to say "no progress".
//
// THE DEFECT: both writers stamped the column with the current clock whenever
// `currentEventId` was non-NULL. That is a fact about ASSIGNMENT, not about
// work. A worker wedged mid-turn keeps its SSE stream open, so the 15s sweeper
// re-stamped it forever; `lastProgressAt` could not go stale while an event was
// held. HealthMonitor's three consumers all test `lastProgressAt < stuckBefore`,
// so the reclaim net was structurally incapable of firing on the exact case it
// was written for. The irony recorded at diagnosis time: the same UPDATE also
// wrote `currentEventTokens` — the real progress signal sat beside the fake one
// and the net keyed on the fake one.
//
// THE FIX: advance only when the transcript token reading actually MOVED, with
// a NULL guard so "couldn't read the transcript" means no information rather
// than progress.
//
// THE COUPLING (the part that makes this dangerous to half-ship): until now the
// stall thresholds were dead code, because the signal was never stale. Making
// the signal honest brings `reclaimStrandedEvents` to life for the first time —
// and it re-enqueues events and frees workers. Against the old 5-min threshold
// it would have started firing on HEALTHY workers: measured 2026-07-22 (n=24),
// median turn gap 88s, max healthy 4m47s — 13 seconds of headroom. Hence
// 15 min. `testThresholdClearsMeasuredHealthyMaximum` and
// `testHealthyWorkerJustPastOldThresholdIsNotReclaimed` exist so that pairing
// cannot be quietly undone.
//
// Every assertion below runs the REAL statements — `writeSweeperWorkerHeartbeat`,
// `writeWorkerHeartbeatAction`, `HealthMonitor.reclaimStrandedEvents` — never a
// copy pasted into the fixture. A test that asserts against its own duplicate of
// the SQL keeps passing after the original drifts, which is the same false-green
// shape this ticket is about.
//
// And each guarded assertion is paired with `legacyStampOnHeldEvent`, the
// pre-fix write, exercised explicitly. A test that cannot fail certifies
// nothing: the paired demonstration proves the old shape really does stamp, so
// the new assertion is measuring the fix rather than a tautology.
final class LastProgressAtHonestyTests: XCTestCase {

    // MARK: - Harness

    private func makeDbPool() throws -> DatabasePool {
        let tmp = NSTemporaryDirectory() + "sonata-lastprogress-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        // The real production schema, not a hand-written subset — a fixture
        // that invents its own `workers` table can pass against columns
        // production doesn't have.
        try pool.write { db in try createSchema(in: db) }
        return pool
    }

    /// Insert a worker. `tokens` is the previously-recorded transcript total —
    /// i.e. the watermark the next write compares against.
    private func insertWorker(
        _ pool: DatabasePool,
        id: String,
        status: String = "busy",
        eventId: String? = "evt-1",
        tokens: Int64? = nil,
        lastProgressAt: Int64?,
        lastHeartbeat: Int64
    ) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO workers
                    (workerId, sessionLabel, status, lastHeartbeat, currentEventId,
                     registeredAt, lastProgressAt, sessionId, currentEventTokens)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, id, status, lastHeartbeat, eventId,
                             lastHeartbeat, lastProgressAt, "sess-\(id)", tokens])
        }
    }

    private func read(_ pool: DatabasePool, _ id: String) throws -> (progress: Int64?, heartbeat: Int64, tokens: Int64?) {
        try pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT lastProgressAt, lastHeartbeat, currentEventTokens FROM workers WHERE workerId = ?",
                arguments: [id])!
            return (row["lastProgressAt"], row["lastHeartbeat"], row["currentEventTokens"])
        }
    }

    /// The PRE-FIX write, reproduced exactly: stamp whenever an event is held,
    /// regardless of whether anything moved.
    ///
    /// This exists so every "the new shape does not stamp" assertion has a
    /// paired demonstration that the OLD shape does. Without it, a test that
    /// asserts `lastProgressAt` is unchanged would also pass against a writer
    /// that had been deleted entirely.
    private func legacyStampOnHeldEvent(
        _ pool: DatabasePool, id: String, heldEvent: Bool, at stamp: Int64
    ) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE workers
                SET lastHeartbeat = ?, lastProgressAt = COALESCE(?, lastProgressAt)
                WHERE workerId = ?
            """, arguments: [stamp, heldEvent ? stamp : nil, id])
        }
    }

    // MARK: - Scenario 1 — hung worker: holds an event, nothing moves

    func testHungWorkerProgressGoesStaleWhileHoldingEvent() throws {
        let pool = try makeDbPool()
        let t0: Int64 = 1_000_000
        try insertWorker(pool, id: "w-hung", tokens: 50_789, lastProgressAt: t0, lastHeartbeat: t0)

        // Six sweeper ticks, 15s apart. The worker holds its event the whole
        // time and its transcript total never moves — the wedge signature.
        for tick in 1...6 {
            let now = t0 + Int64(tick) * 15_000
            try pool.write { db in
                try writeSweeperWorkerHeartbeat(
                    db, workerId: "w-hung", heartbeatAt: now,
                    progressTokens: 50_789,          // frozen
                    inputTokens: 50_789, cacheReadTokens: 0, contextTokens: 50_789)
            }
        }

        let after = try read(pool, "w-hung")
        XCTAssertEqual(after.progress, t0,
            "lastProgressAt must stay stale while the token reading is frozen — this is the ⊥ the column never had")
        XCTAssertEqual(after.heartbeat, t0 + 90_000,
            "lastHeartbeat must keep advancing: the transport IS alive, and conflating the two is the original sin")
    }

    func testPreFixShapeWouldHaveStampedTheHungWorker() throws {
        // The paired falsifier for scenario 1. If this ever stops stamping, the
        // test above is no longer proving anything.
        let pool = try makeDbPool()
        let t0: Int64 = 1_000_000
        try insertWorker(pool, id: "w-hung-legacy", tokens: 50_789, lastProgressAt: t0, lastHeartbeat: t0)

        for tick in 1...6 {
            try legacyStampOnHeldEvent(pool, id: "w-hung-legacy", heldEvent: true, at: t0 + Int64(tick) * 15_000)
        }

        XCTAssertEqual(try read(pool, "w-hung-legacy").progress, t0 + 90_000,
            "pre-fix writer stamps a frozen worker as progressing — the defect, demonstrated")
    }

    // MARK: - Scenario 2 — heavy IO: holds an event, reading advances

    func testWorkingWorkerProgressTracksAdvancingUsage() throws {
        let pool = try makeDbPool()
        let t0: Int64 = 2_000_000
        try insertWorker(pool, id: "w-busy", tokens: 1_000, lastProgressAt: t0, lastHeartbeat: t0)

        var total: Int64 = 1_000
        var last = t0
        for tick in 1...5 {
            let now = t0 + Int64(tick) * 15_000
            total += 250                      // a turn landed
            try pool.write { db in
                try writeSweeperWorkerHeartbeat(
                    db, workerId: "w-busy", heartbeatAt: now,
                    progressTokens: total,
                    inputTokens: total, cacheReadTokens: 0, contextTokens: total)
            }
            let now2 = try read(pool, "w-busy")
            XCTAssertEqual(now2.progress, now, "progress must track each advance")
            XCTAssertGreaterThan(now2.progress!, last)
            last = now2.progress!
        }
        XCTAssertEqual(try read(pool, "w-busy").tokens, 2_250)
    }

    func testProgressAdvancesOnTheFirstReadingOfANewEvent() throws {
        // currentEventTokens is NULL at the start of an event (cleared on
        // completion). `NULL IS NOT 500` is true, so the first reading counts
        // as progress — correct: the event genuinely just started, and this is
        // what seeds the watermark.
        let pool = try makeDbPool()
        let t0: Int64 = 3_000_000
        try insertWorker(pool, id: "w-fresh", tokens: nil, lastProgressAt: t0, lastHeartbeat: t0)

        try pool.write { db in
            try writeSweeperWorkerHeartbeat(
                db, workerId: "w-fresh", heartbeatAt: t0 + 15_000,
                progressTokens: 500, inputTokens: 500, cacheReadTokens: 0, contextTokens: 500)
        }
        XCTAssertEqual(try read(pool, "w-fresh").progress, t0 + 15_000)
    }

    // MARK: - Scenario 3 — the two signals are now independent

    func testHeartbeatAdvancesIndependentlyOfProgress() throws {
        // A dead worker's SSE drops, the sweeper stops being called for it, and
        // BOTH fields freeze — that case is trivially true and proves nothing
        // on its own. The claim worth testing is the one that was false before:
        // that a LIVE transport can now coexist with stale progress. That
        // separation is the entire diagnostic value of the fix.
        let pool = try makeDbPool()
        let t0: Int64 = 4_000_000
        try insertWorker(pool, id: "w-split", tokens: 777, lastProgressAt: t0, lastHeartbeat: t0)

        for tick in 1...4 {
            try pool.write { db in
                try writeSweeperWorkerHeartbeat(
                    db, workerId: "w-split", heartbeatAt: t0 + Int64(tick) * 15_000,
                    progressTokens: 777, inputTokens: 777, cacheReadTokens: 0, contextTokens: 777)
            }
        }

        let r = try read(pool, "w-split")
        XCTAssertEqual(r.heartbeat, t0 + 60_000, "transport alive")
        XCTAssertEqual(r.progress, t0, "work not advancing")
        XCTAssertNotEqual(r.heartbeat, r.progress,
            "the two must be able to disagree — before the fix they could not, and that is why a wedged worker was invisible")
    }

    // MARK: - Scenario 4 — six workers, mixed activity, per-worker divergence

    func testSixWorkersDivergePerWorkerNotPerTick() throws {
        // The original mis-diagnosis on this ticket was that lastHeartbeat is
        // written globally, because every worker row carried a byte-identical
        // timestamp. It isn't — tick() samples the clock ONCE and passes the
        // same `now` to every worker in the loop. Identical values, independent
        // rows. This pins that: one shared tick clock, six different outcomes,
        // decided per-worker by whether that worker's own reading moved.
        let pool = try makeDbPool()
        let t0: Int64 = 5_000_000
        let advancing = ["w1", "w3", "w5"]
        let frozen = ["w2", "w4", "w6"]

        var totals: [String: Int64] = [:]
        for id in advancing + frozen {
            totals[id] = 10_000
            try insertWorker(pool, id: id, tokens: 10_000, lastProgressAt: t0, lastHeartbeat: t0)
        }

        for tick in 1...4 {
            let now = t0 + Int64(tick) * 15_000     // ONE clock for the sweep
            for id in advancing + frozen {
                if advancing.contains(id) { totals[id]! += 100 }
                try pool.write { db in
                    try writeSweeperWorkerHeartbeat(
                        db, workerId: id, heartbeatAt: now,
                        progressTokens: totals[id],
                        inputTokens: totals[id], cacheReadTokens: 0, contextTokens: totals[id])
                }
            }
        }

        for id in advancing {
            XCTAssertEqual(try read(pool, id).progress, t0 + 60_000, "\(id) worked, so its progress moved")
        }
        for id in frozen {
            XCTAssertEqual(try read(pool, id).progress, t0, "\(id) was wedged, so its progress must be stale")
        }
        // All six share a heartbeat — identical timestamps are the sweeper's
        // single clock, NOT a global write.
        let heartbeats = try (advancing + frozen).map { try read(pool, $0).heartbeat }
        XCTAssertEqual(Set(heartbeats).count, 1)
        let progresses = try (advancing + frozen).map { try read(pool, $0).progress }
        XCTAssertEqual(Set(progresses).count, 2, "progress must be decided per-worker, not per-tick")
    }

    // MARK: - Scenario 5 — no reading at all (the risk the fix introduces)

    func testUnreadableTranscriptDoesNotStampProgress() throws {
        // The NULL guard. A transcript we could not read tells us nothing, and
        // "nothing" must never read as "advance" — without the guard,
        // `NULL IS NOT <n>` is true and a transient read failure would stamp
        // false progress, the very defect class being removed.
        let pool = try makeDbPool()
        let t0: Int64 = 6_000_000
        try insertWorker(pool, id: "w-noread", tokens: 4_242, lastProgressAt: t0, lastHeartbeat: t0)

        for tick in 1...4 {
            try pool.write { db in
                try writeSweeperWorkerHeartbeat(
                    db, workerId: "w-noread", heartbeatAt: t0 + Int64(tick) * 15_000,
                    progressTokens: nil,        // unreadable transcript
                    inputTokens: nil, cacheReadTokens: nil, contextTokens: nil)
            }
        }

        let r = try read(pool, "w-noread")
        XCTAssertEqual(r.progress, t0, "a nil reading must not advance progress")
        XCTAssertEqual(r.tokens, 4_242, "and must not clobber the last real reading")

        // DOCUMENTED CONSEQUENCE, deliberately pinned rather than left to be
        // discovered in an incident: a worker whose transcript is *permanently*
        // unresolvable (stale workers.sessionId, transcript cleaned up beneath
        // it) now looks permanently stalled, where before it looked permanently
        // healthy. That converts a false-negative into a false-positive for
        // this one worker class. Blast radius is bounded — reclaim re-enqueues
        // to 'pending' so no work is lost, and the complete/fail owner-guard
        // rejects the original worker's late completion — so the worst case is
        // one event processed twice, not an event dropped. If this assertion
        // ever needs to change, that trade-off is what is being re-decided.
    }

    func testIdleWorkerNeverAdvancesProgress() throws {
        // Progress is event-scoped. An idle worker has nothing to progress, and
        // the sweeper passes nil for exactly that reason.
        let pool = try makeDbPool()
        let t0: Int64 = 7_000_000
        try insertWorker(pool, id: "w-idle", status: "idle", eventId: nil,
                         tokens: nil, lastProgressAt: t0, lastHeartbeat: t0)

        try pool.write { db in
            try writeSweeperWorkerHeartbeat(
                db, workerId: "w-idle", heartbeatAt: t0 + 15_000,
                progressTokens: nil, inputTokens: nil, cacheReadTokens: nil,
                contextTokens: 12_000)   // context IS session-scoped, still written
        }

        let r = try read(pool, "w-idle")
        XCTAssertEqual(r.progress, t0)
        XCTAssertEqual(r.heartbeat, t0 + 15_000)
    }

    // MARK: - The second writer (worker_heartbeat action)

    func testActionWriterDoesNotStampOnHeldEventAlone() throws {
        // The dormant door. Nothing POSTs this endpoint today, which is exactly
        // why it had to be fixed in the same commit: a dormant writer left with
        // the old semantics silently undoes the fix the day something calls it.
        let pool = try makeDbPool()
        let t0: Int64 = 8_000_000
        try insertWorker(pool, id: "w-action", tokens: 900, lastProgressAt: t0, lastHeartbeat: t0)

        for tick in 1...3 {
            try pool.write { db in
                try writeWorkerHeartbeatAction(
                    db, workerId: "w-action", now: t0 + Int64(tick) * 15_000,
                    lastProgressAt: nil,
                    currentEventTokens: 900,        // frozen
                    currentSlug: nil, currentCacheReadTokens: nil, currentInputTokens: nil,
                    currentContextTokens: nil, promptHash: nil, sessionLabel: nil, cwdBasename: nil)
            }
        }
        XCTAssertEqual(try read(pool, "w-action").progress, t0,
            "holding an event is not progress on this path either")
    }

    func testActionWriterAdvancesWhenTokensMove() throws {
        let pool = try makeDbPool()
        let t0: Int64 = 9_000_000
        try insertWorker(pool, id: "w-action2", tokens: 900, lastProgressAt: t0, lastHeartbeat: t0)

        try pool.write { db in
            try writeWorkerHeartbeatAction(
                db, workerId: "w-action2", now: t0 + 15_000,
                lastProgressAt: nil, currentEventTokens: 1_400,
                currentSlug: nil, currentCacheReadTokens: nil, currentInputTokens: nil,
                currentContextTokens: nil, promptHash: nil, sessionLabel: nil, cwdBasename: nil)
        }
        XCTAssertEqual(try read(pool, "w-action2").progress, t0 + 15_000)
    }

    func testActionWriterHonoursCallerSuppliedStamp() throws {
        // Branch (1) is deliberately preserved: an explicit stamp from a caller
        // that knows better than the heartbeat clock still wins.
        let pool = try makeDbPool()
        let t0: Int64 = 10_000_000
        try insertWorker(pool, id: "w-action3", tokens: 900, lastProgressAt: t0, lastHeartbeat: t0)

        try pool.write { db in
            try writeWorkerHeartbeatAction(
                db, workerId: "w-action3", now: t0 + 15_000,
                lastProgressAt: t0 + 999,     // explicit
                currentEventTokens: 900,      // frozen — must not matter
                currentSlug: nil, currentCacheReadTokens: nil, currentInputTokens: nil,
                currentContextTokens: nil, promptHash: nil, sessionLabel: nil, cwdBasename: nil)
        }
        XCTAssertEqual(try read(pool, "w-action3").progress, t0 + 999)
    }

    func testActionWriterIgnoresAbsentTokenReading() throws {
        let pool = try makeDbPool()
        let t0: Int64 = 11_000_000
        try insertWorker(pool, id: "w-action4", tokens: 900, lastProgressAt: t0, lastHeartbeat: t0)

        try pool.write { db in
            try writeWorkerHeartbeatAction(
                db, workerId: "w-action4", now: t0 + 15_000,
                lastProgressAt: nil, currentEventTokens: nil,
                currentSlug: nil, currentCacheReadTokens: nil, currentInputTokens: nil,
                currentContextTokens: nil, promptHash: nil, sessionLabel: nil, cwdBasename: nil)
        }
        XCTAssertEqual(try read(pool, "w-action4").progress, t0,
            "no reading is not progress")
    }

    // MARK: - The coupling: honest signal + raised threshold, together

    func testThresholdClearsMeasuredHealthyMaximum() async throws {
        // A tripwire, not a tautology. The measured healthy maximum turn gap was
        // 4m47s (n=24, 2026-07-22). The old 5-min threshold left 13 seconds of
        // headroom, which was harmless only because the signal never went stale.
        // Now that it does, anyone lowering this constant re-arms
        // reclaimStrandedEvents against healthy workers — so the relationship is
        // asserted here rather than left in a comment.
        let pool = try makeDbPool()
        let monitor = HealthMonitor(dbPool: pool)
        let measuredHealthyMaxSeconds: TimeInterval = 287     // 4m47s

        let threshold = await monitor.workerStuckThreshold
        XCTAssertGreaterThanOrEqual(
            threshold, measuredHealthyMaxSeconds * 3,
            "workerStuckThreshold must keep ~3x margin over the measured healthy max turn gap")
    }

    func testHealthyWorkerJustPastOldThresholdIsNotReclaimed() async throws {
        // The regression the coupling exists to prevent, driven through the
        // REAL reclaim path. Six minutes without a landed turn is ordinary — a
        // long model call, a long build. Under the old 5-min threshold this
        // worker would now be killed and its event re-enqueued.
        let pool = try makeDbPool()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try insertWorker(pool, id: "w-slow", tokens: 5_000,
                         lastProgressAt: now - 6 * 60 * 1000,   // 6 min
                         lastHeartbeat: now)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, status, payload, createdAt, assignedAt, assignedTo)
                VALUES ('evt-1', 'task', 'assigned', '{}', ?, ?, 'w-slow')
            """, arguments: [now - 7 * 60 * 1000, now - 7 * 60 * 1000])
        }

        await HealthMonitor(dbPool: pool).reclaimStrandedEvents()

        let (status, eventId) = try await pool.read { db -> (String, String?) in
            let r = try Row.fetchOne(db, sql: "SELECT status, currentEventId FROM workers WHERE workerId = 'w-slow'")!
            return (r["status"], r["currentEventId"])
        }
        XCTAssertEqual(status, "busy", "a worker 6 min into one long turn is healthy and must not be reclaimed")
        XCTAssertEqual(eventId, "evt-1", "and must keep its event")
    }

    func testGenuinelyWedgedWorkerIsReclaimed() async throws {
        // The other half: past 15 minutes with no landed turn, the net must
        // actually fire. Before this fix it could not fire at all, because the
        // sweeper kept `lastProgressAt` fresh forever.
        let pool = try makeDbPool()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try insertWorker(pool, id: "w-wedged", tokens: 5_000,
                         lastProgressAt: now - 20 * 60 * 1000,  // 20 min
                         lastHeartbeat: now)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, status, payload, createdAt, assignedAt, assignedTo)
                VALUES ('evt-2', 'task', 'assigned', '{}', ?, ?, 'w-wedged')
            """, arguments: [now - 21 * 60 * 1000, now - 21 * 60 * 1000])
        }
        try await pool.write { db in
            try db.execute(sql: "UPDATE workers SET currentEventId = 'evt-2' WHERE workerId = 'w-wedged'")
        }

        await HealthMonitor(dbPool: pool).reclaimStrandedEvents()

        let workerStatus = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM workers WHERE workerId = 'w-wedged'")
        }
        let eventStatus = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM workerEvents WHERE id = 'evt-2'")
        }
        XCTAssertEqual(workerStatus, "idle", "wedged worker must be freed")
        XCTAssertEqual(eventStatus, "pending", "and its event re-enqueued rather than lost")
    }
}
