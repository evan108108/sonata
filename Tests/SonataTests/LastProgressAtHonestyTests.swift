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
        eventTokens: Int64? = nil,
        lastProgressAt: Int64?,
        lastHeartbeat: Int64
    ) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO workers
                    (workerId, sessionLabel, status, lastHeartbeat, currentEventId,
                     registeredAt, lastProgressAt, sessionId, currentEventTokens,
                     lastProgressTokens)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, id, status, lastHeartbeat, eventId,
                             lastHeartbeat, lastProgressAt, "sess-\(id)", eventTokens, tokens])
        }
    }

    private func read(_ pool: DatabasePool, _ id: String) throws -> (progress: Int64?, heartbeat: Int64, tokens: Int64?, watermark: Int64?) {
        try pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT lastProgressAt, lastHeartbeat, currentEventTokens, lastProgressTokens
                    FROM workers WHERE workerId = ?
                """,
                arguments: [id])!
            return (row["lastProgressAt"], row["lastHeartbeat"],
                    row["currentEventTokens"], row["lastProgressTokens"])
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
                    inFlight: true,
                    sampledTotal: 50_789,            // frozen
                    eventTokens: 50_789,
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
                    inFlight: true, sampledTotal: total, eventTokens: total,
                    inputTokens: total, cacheReadTokens: 0, contextTokens: total)
            }
            let now2 = try read(pool, "w-busy")
            XCTAssertEqual(now2.progress, now, "progress must track each advance")
            XCTAssertGreaterThan(now2.progress!, last)
            last = now2.progress!
        }
        XCTAssertEqual(try read(pool, "w-busy").tokens, 2_250)
    }

    // MARK: - Scenario 9 — the watermark must be SESSION-scoped, not event-scoped
    //
    // This is the test that catches the silent incompatibility between the two
    // parallel implementations of this fix, and it is the reason a new column
    // exists rather than a reuse of `currentEventTokens`.
    //
    // Every RELEASE path (complete/fail/clear_current_event/reconcile/reclaim/
    // stale-sweep) sets `currentEventTokens = NULL`, and no ASSIGNMENT path
    // writes it. So a freshly-assigned event always begins with that column
    // NULL — and `NULL IS NOT <total>` is TRUE in SQLite. A watermark read from
    // it would therefore stamp `lastProgressAt` on the first sweep after EVERY
    // assignment, including for a worker that never received its event. That
    // pushes `lastProgressAt` past `assignedAt` and makes
    // `reclaimStrandedEvents` structurally unable to fire — the same dead-net
    // outcome as the original defect, wearing a different mechanism, with every
    // other test in this file still green.

    func testStrandedWorkerDoesNotStampOnTheFirstSweepAfterAssignment() throws {
        let pool = try makeDbPool()
        let assignedAt: Int64 = 3_000_000
        // The shape a real worker is in one tick after assignment: it finished a
        // previous event (so currentEventTokens was NULLed), it carries a
        // session-scoped watermark from that work, and its progress predates the
        // new assignment because it never received it.
        try insertWorker(pool, id: "w-stranded",
                         tokens: 50_000,          // lastProgressTokens — session watermark
                         eventTokens: nil,        // currentEventTokens — NULLed on release
                         lastProgressAt: assignedAt - 60_000,
                         lastHeartbeat: assignedAt)

        // Sweep: transcript total UNCHANGED, because no turn has run.
        try pool.write { db in
            try writeSweeperWorkerHeartbeat(
                db, workerId: "w-stranded", heartbeatAt: assignedAt + 15_000,
                inFlight: true, sampledTotal: 50_000, eventTokens: 50_000,
                inputTokens: 50_000, cacheReadTokens: 0, contextTokens: 50_000)
        }

        let r = try read(pool, "w-stranded")
        XCTAssertEqual(r.progress, assignedAt - 60_000,
            "a stranded worker must NOT be stamped just because currentEventTokens was NULL")
        XCTAssertLessThan(r.progress!, assignedAt,
            "and must stay below assignedAt, or reclaimStrandedEvents can never fire")
    }

    func testEventScopedWatermarkWouldHaveStampedTheStrandedWorker() throws {
        // The paired falsifier. Runs the REJECTED comparison — against the
        // event-scoped column — and shows it produces the false stamp. Without
        // this, the assertion above would keep passing against any writer that
        // simply never stamps, and would prove nothing about the scope choice.
        let pool = try makeDbPool()
        let assignedAt: Int64 = 3_000_000
        try insertWorker(pool, id: "w-stranded-legacy",
                         tokens: 50_000, eventTokens: nil,
                         lastProgressAt: assignedAt - 60_000, lastHeartbeat: assignedAt)

        try pool.write { db in
            try db.execute(sql: """
                UPDATE workers
                SET lastProgressAt = CASE
                        WHEN ? IS NOT NULL AND currentEventTokens IS NOT ? THEN ?
                        ELSE lastProgressAt
                    END
                WHERE workerId = ?
            """, arguments: [50_000, 50_000, assignedAt + 15_000, "w-stranded-legacy"])
        }

        let r = try read(pool, "w-stranded-legacy")
        XCTAssertEqual(r.progress, assignedAt + 15_000,
            "event-scoped watermark stamps a worker that did nothing — the vacuous reconciliation, demonstrated")
        XCTAssertGreaterThan(r.progress!, assignedAt,
            "which is exactly what would have made the assignedAt predicate unable to fire")
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
                    inFlight: true, sampledTotal: 777, eventTokens: 777,
                    inputTokens: 777, cacheReadTokens: 0, contextTokens: 777)
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
                        inFlight: true,
                        sampledTotal: totals[id], eventTokens: totals[id],
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

    // MARK: - Scenario 5 — no reading at all
    //
    // THIS ASSERTION WAS INVERTED ON 2026-08-04, and the inversion is the point.
    //
    // The first version of this fix treated a nil reading as "do not advance",
    // and pinned the consequence as a documented trade-off: a worker whose
    // transcript is permanently unresolvable would look permanently stalled.
    // That was tolerable only while the reclaim path used a DURATION threshold.
    //
    // Once `reclaimStrandedEvents` keys on `assignedAt`, the same choice stops
    // being a trade-off and becomes a live false positive: an unreadable
    // transcript holds `lastProgressAt` below `assignedAt` forever, so the
    // worker is reclaimed every single cycle for as long as it exists.
    //
    // The deeper error was mine and it has a name already in the graph:
    // asserting a hang from an absence of evidence is `empty-result-read-as-
    // absence`. "We could not observe work" is not "no work happened", and this
    // decision feeds a reaper that re-enqueues live events. Degrading to the old
    // transport-clock behaviour is the conservative failure; asserting a hang is
    // not. Recovering the resulting false NEGATIVE costs one supervisor pass;
    // the false POSITIVE costs duplicated work.

    func testUnreadableTranscriptStampsRatherThanAssertingAHang() throws {
        let pool = try makeDbPool()
        let t0: Int64 = 6_000_000
        try insertWorker(pool, id: "w-noread", tokens: 4_242, eventTokens: 4_242,
                         lastProgressAt: t0, lastHeartbeat: t0)

        try pool.write { db in
            try writeSweeperWorkerHeartbeat(
                db, workerId: "w-noread", heartbeatAt: t0 + 15_000,
                inFlight: true,
                sampledTotal: nil,          // unreadable transcript
                eventTokens: nil,
                inputTokens: nil, cacheReadTokens: nil, contextTokens: nil)
        }

        let r = try read(pool, "w-noread")
        XCTAssertEqual(r.progress, t0 + 15_000,
            "a nil reading must ADVANCE — we could not observe work, which is not the same as no work")
        XCTAssertEqual(r.watermark, 4_242, "and must not clobber the last real watermark")
        XCTAssertEqual(r.tokens, 4_242, "nor the last real event reading")
    }

    func testNoBaselineDoesNotStamp() throws {
        // The other half of the nil story, and the opposite answer. A worker with
        // a reading but NO watermark has nothing to compare against. Stamping
        // here would hand a genuinely stranded worker a fresh timestamp on its
        // first sweep — which is exactly the blindness being removed. Costs a
        // working worker one 15s tick, because the same statement writes the
        // baseline it was missing.
        let pool = try makeDbPool()
        let t0: Int64 = 6_500_000
        try insertWorker(pool, id: "w-nobase", tokens: nil, eventTokens: nil,
                         lastProgressAt: t0, lastHeartbeat: t0)

        try pool.write { db in
            try writeSweeperWorkerHeartbeat(
                db, workerId: "w-nobase", heartbeatAt: t0 + 15_000,
                inFlight: true, sampledTotal: 9_000, eventTokens: 9_000,
                inputTokens: 9_000, cacheReadTokens: 0, contextTokens: 9_000)
        }
        var r = try read(pool, "w-nobase")
        XCTAssertEqual(r.progress, t0, "no baseline yet — must not stamp")
        XCTAssertEqual(r.watermark, 9_000, "but the baseline is now established")

        // Next tick with real movement stamps normally.
        try pool.write { db in
            try writeSweeperWorkerHeartbeat(
                db, workerId: "w-nobase", heartbeatAt: t0 + 30_000,
                inFlight: true, sampledTotal: 9_500, eventTokens: 9_500,
                inputTokens: 9_500, cacheReadTokens: 0, contextTokens: 9_500)
        }
        r = try read(pool, "w-nobase")
        XCTAssertEqual(r.progress, t0 + 30_000, "one tick later, movement stamps")
    }

    func testIdleWorkerNeverAdvancesProgress() throws {
        // Progress is a claim about an event being worked. A worker holding
        // nothing has none to make — even though its session-scoped columns are
        // still written.
        let pool = try makeDbPool()
        let t0: Int64 = 7_000_000
        try insertWorker(pool, id: "w-idle", status: "idle", eventId: nil,
                         tokens: 500, eventTokens: nil, lastProgressAt: t0, lastHeartbeat: t0)

        try pool.write { db in
            try writeSweeperWorkerHeartbeat(
                db, workerId: "w-idle", heartbeatAt: t0 + 15_000,
                inFlight: false,
                sampledTotal: 9_999,   // reading moved, but the worker is idle
                eventTokens: nil,
                inputTokens: nil, cacheReadTokens: nil,
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

    // MARK: - The coupling: honest signal + the right predicate + split constants

    func testThresholdConstantsAreDistinctQuantities() async throws {
        // A tripwire, not a tautology. These were ONE overloaded constant until
        // 2026-08-04, and collapsing them again is the cheap mistake: they
        // measure different things — how old an EVENT is, versus how long a
        // WORKER has been quiet — and the right values differ by 9x.
        //
        // The progress threshold is bounded by what the signal measures. A
        // transcript grows only when a TURN LANDS, so a worker inside one long
        // tool call correctly reads as "no progress" for that call's duration.
        // Measured across 36,199 tool-wait gaps in the pool's own transcripts:
        // p99 1.1 min, p99.9 8.1 min, but 16 gaps exceeded 20 min (real builds
        // and test suites). Anything at or below that tail false-positives on
        // healthy workers.
        let pool = try makeDbPool()
        let monitor = HealthMonitor(dbPool: pool)
        let measuredLongHealthyGapSeconds: TimeInterval = 20 * 60   // 16 gaps exceeded this

        let eventAge = await monitor.workerStuckThreshold
        let progressStale = await monitor.workerProgressStaleThreshold

        XCTAssertNotEqual(eventAge, progressStale,
            "event-age and progress-staleness must not be the same constant again")
        XCTAssertGreaterThan(progressStale, measuredLongHealthyGapSeconds,
            "progress-staleness must clear the measured long-tail healthy tool-wait gap")
        XCTAssertLessThan(eventAge, progressStale,
            "the assign->deliver grace is a much shorter quantity than a quiet-worker timeout")
    }

    func testHealthyWorkerOnALongBuildIsNotReclaimed() async throws {
        // THE REGRESSION THE PREDICATE CHANGE EXISTS TO PREVENT, driven through
        // the REAL reclaim path.
        //
        // This worker received its event and answered it with a model turn, then
        // entered a 25-minute build. Under ANY duration threshold — including
        // the 15 min a previous revision of this fix shipped — it reads as "no
        // progress" and gets its event re-enqueued underneath it, duplicating
        // work. Keyed on assignedAt it is immune no matter how long the build
        // runs, because it demonstrably answered the event.
        let pool = try makeDbPool()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let assignedAt = now - 30 * 60 * 1000              // assigned 30 min ago
        try insertWorker(pool, id: "w-build", tokens: 5_000,
                         lastProgressAt: assignedAt + 60_000,   // answered it, then went quiet 25 min
                         lastHeartbeat: now)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, status, payload, createdAt, assignedAt, assignedTo)
                VALUES ('evt-1', 'task', 'assigned', '{}', ?, ?, 'w-build')
            """, arguments: [assignedAt, assignedAt])
        }

        await HealthMonitor(dbPool: pool).reclaimStrandedEvents()

        let (status, eventId) = try await pool.read { db -> (String, String?) in
            let r = try Row.fetchOne(db, sql: "SELECT status, currentEventId FROM workers WHERE workerId = 'w-build'")!
            return (r["status"], r["currentEventId"])
        }
        XCTAssertEqual(status, "busy",
            "a worker 25 min into one long build has made progress SINCE assignment and must not be reclaimed")
        XCTAssertEqual(eventId, "evt-1", "and must keep its event")
    }

    func testWorkerInsideTheAssignmentGraceIsNotJudged() async throws {
        // The remaining use of workerStuckThreshold: an event still inside the
        // normal assign->deliver->first-turn window is not judged at all, even
        // though its holder has, correctly, no progress since assignment yet.
        let pool = try makeDbPool()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let assignedAt = now - 60_000                       // 1 min ago, inside the 5-min grace
        try insertWorker(pool, id: "w-fresh-evt", tokens: 5_000,
                         lastProgressAt: assignedAt - 30_000,   // nothing since assignment
                         lastHeartbeat: now)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, status, payload, createdAt, assignedAt, assignedTo)
                VALUES ('evt-3', 'task', 'assigned', '{}', ?, ?, 'w-fresh-evt')
            """, arguments: [assignedAt, assignedAt])
        }

        await HealthMonitor(dbPool: pool).reclaimStrandedEvents()

        let status = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM workers WHERE workerId = 'w-fresh-evt'")
        }
        XCTAssertEqual(status, "busy", "an event one minute old has not had a chance to start")
    }

    func testGenuinelyStrandedWorkerIsReclaimed() async throws {
        // The other half: a worker that never answered its event must still be
        // caught, and now for the right reason — no model turn SINCE assignment,
        // rather than "quiet for longer than N". Before this fix it could not be
        // caught at all: the sweeper kept `lastProgressAt` fresh forever.
        //
        // Note this fires with only a 6-minute-old event, just past the grace.
        // The duration-threshold version would have needed to wait out its whole
        // timeout before acting on the same certainty.
        let pool = try makeDbPool()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let assignedAt = now - 6 * 60 * 1000
        try insertWorker(pool, id: "w-wedged", tokens: 5_000,
                         lastProgressAt: assignedAt - 30_000,   // frozen BEFORE assignment
                         lastHeartbeat: now)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, status, payload, createdAt, assignedAt, assignedTo)
                VALUES ('evt-2', 'task', 'assigned', '{}', ?, ?, 'w-wedged')
            """, arguments: [assignedAt, assignedAt])
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

    // MARK: - The signal has to REACH the decision that misfired

    func testWorkerListProjectsLastProgressAt() throws {
        // Fixing the writer without projecting to the reader ships an honest
        // signal nobody can see. The column existed in `workers` for a month,
        // but `worker_list` did not return it — so the supervisor, the one
        // consumer whose entire job is judging liveness, hand-rolled "identical
        // token counts for 3 cycles" instead and escalated a healthy worker as
        // frozen, minutes from a kill mid-ticket.
        //
        // Asserted against the real encoder rather than the struct's stored
        // property: a field can be present in memory and still be dropped on the
        // way to the wire, and the wire is what the supervisor reads.
        let item = WorkerListItem(
            _id: "row-1", workerId: "w-1", sessionLabel: "sona-worker-1",
            status: "busy", capabilities: "[]",
            lastHeartbeat: 1_700_000_000_000,
            lastProgressAt: 1_699_999_000_000,
            currentEventId: "evt-1", registeredAt: 1_600_000_000_000,
            currentTask: nil, assignedAt: nil, currentEventTokens: nil,
            currentSlug: nil, currentCacheReadTokens: nil, currentInputTokens: nil,
            currentContextTokens: nil)

        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(item)) as! [String: Any]

        XCTAssertEqual(json["lastProgressAt"] as? Int64, 1_699_999_000_000,
            "lastProgressAt must reach the wire, not just the struct")
        XCTAssertNotEqual(json["lastProgressAt"] as? Int64, json["lastHeartbeat"] as? Int64,
            "and must be carried as its own quantity — conflating the two is the original defect")
    }
}
