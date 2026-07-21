import XCTest
import GRDB
import Logging
@testable import Sonata

// Tests for the wedged-rotation fallback in `SidecarLifecycle`.
//
// THE FAILURE THIS EXISTS FOR: the monitor posts `rotate_me` when a sidecar
// crosses its context threshold and latches `rotateRequested` so it doesn't
// re-post every 30s. The latch is cleared by `spawn`, on the far side of a
// rotation that only happens when the sidecar COMPLETES that event. If it
// never does — a bug in its SKILL, a model refusal, a wedged agent — the latch
// stays set, the monitor stays quiet, and the sidecar sits above its threshold
// forever. `worker_event_complete` is still the primary route; this is the
// safety net under it.
//
// The interesting part is not "does a timeout fire" — it is that the timeout
// must not fire on a sidecar that is merely SLOW. Four conditions gate it, and
// most of these tests exist to prove each one can veto on its own.
final class SidecarWedgeFallbackTests: XCTestCase {

    // Names for the readings under test, so the cases read as scenarios rather
    // than as arithmetic. Threshold is the `Sidecar.Defaults` value.
    private let threshold = 70
    private let pinnedPct = 82
    private let freshHeartbeatMs: Int64 = 5_000
    private let staleHeartbeatMs: Int64 = 10 * 60 * 1000
    private var pastGraceMs: Int64 { Int64(SidecarLifecycle.rotateGraceSeconds * 1000) + 1 }
    private var withinGraceMs: Int64 { Int64(SidecarLifecycle.rotateGraceSeconds * 1000) - 1 }

    private func decide(
        elapsedSincePostMs: Int64,
        contextPctAtPost: Int,
        previousContextPct: Int,
        currentContextPct: Int?,
        heartbeatAgeMs: Int64?
    ) -> SidecarLifecycle.WedgeDecision {
        SidecarLifecycle.wedgeDecision(
            elapsedSincePostMs: elapsedSincePostMs,
            rotationThreshold: threshold,
            contextPctAtPost: contextPctAtPost,
            previousContextPct: previousContextPct,
            currentContextPct: currentContextPct,
            heartbeatAgeMs: heartbeatAgeMs
        )
    }

    // MARK: - The wedge itself

    /// All four conditions align: latched (implied — the decider is only
    /// reached with an outstanding request), past grace, reading pinned and
    /// flat, process heartbeating.
    func testWedgedSidecarForceRotates() {
        XCTAssertEqual(
            decide(
                elapsedSincePostMs: pastGraceMs,
                contextPctAtPost: pinnedPct,
                previousContextPct: pinnedPct,
                currentContextPct: pinnedPct,
                heartbeatAgeMs: freshHeartbeatMs
            ),
            .forceRotate
        )
    }

    /// Rounding drift is not movement. A reading that wobbles by less than the
    /// tolerance is the same turn measured twice, not a new one — otherwise a
    /// genuinely wedged sidecar would be rescued from the fallback by noise.
    func testSubToleranceDriftStillCountsAsWedged() {
        let drift = SidecarLifecycle.contextMovementTolerancePct - 1
        XCTAssertEqual(
            decide(
                elapsedSincePostMs: pastGraceMs,
                contextPctAtPost: pinnedPct,
                previousContextPct: pinnedPct,
                currentContextPct: pinnedPct + drift,
                heartbeatAgeMs: freshHeartbeatMs
            ),
            .forceRotate
        )
    }

    // MARK: - Condition 2: grace period

    func testWithinGracePeriodWaits() {
        XCTAssertEqual(
            decide(
                elapsedSincePostMs: withinGraceMs,
                contextPctAtPost: pinnedPct,
                previousContextPct: pinnedPct,
                currentContextPct: pinnedPct,
                heartbeatAgeMs: freshHeartbeatMs
            ),
            .withinGracePeriod,
            "a bare timer that fires early would force-rotate a sidecar still working its rotate_me"
        )
    }

    /// The boundary is inclusive — at exactly the grace period the sidecar has
    /// had its full allowance.
    func testExactlyAtGracePeriodRotates() {
        XCTAssertEqual(
            decide(
                elapsedSincePostMs: Int64(SidecarLifecycle.rotateGraceSeconds * 1000),
                contextPctAtPost: pinnedPct,
                previousContextPct: pinnedPct,
                currentContextPct: pinnedPct,
                heartbeatAgeMs: freshHeartbeatMs
            ),
            .forceRotate
        )
    }

    // MARK: - Condition 3: the busy-but-progressing discriminator

    /// THE case this whole check is built around. Latch set, well past grace,
    /// heartbeating — everything a bare timer would look at says "rotate" — but
    /// the reading is climbing, so the session is taking turns. Rotating here
    /// would kill a healthy sidecar mid-work.
    func testBusyButProgressingSidecarDoesNotRotate() {
        XCTAssertEqual(
            decide(
                elapsedSincePostMs: pastGraceMs,
                contextPctAtPost: pinnedPct,
                previousContextPct: pinnedPct + 3,
                currentContextPct: pinnedPct + 7,
                heartbeatAgeMs: freshHeartbeatMs
            ),
            .contextMoving,
            "a sidecar whose context is still climbing is working, not wedged"
        )
    }

    /// The same signal on the short horizon only: flat across the ten minutes
    /// since the post, but moving as of this tick. One tick of life is enough
    /// to wait another cycle.
    func testMovementSinceLastTickAloneDefersRotation() {
        XCTAssertEqual(
            decide(
                elapsedSincePostMs: pastGraceMs,
                contextPctAtPost: pinnedPct,
                previousContextPct: pinnedPct - 6,
                currentContextPct: pinnedPct,
                heartbeatAgeMs: freshHeartbeatMs
            ),
            .contextMoving,
            "drifting away and back must not read as flat — that is why both horizons are checked"
        )
    }

    /// A real rotation through agent completion drops the reading when the
    /// fresh session spawns. Below threshold, there is nothing left to fix.
    func testContextDroppedBelowThresholdDoesNotRotate() {
        XCTAssertEqual(
            decide(
                elapsedSincePostMs: pastGraceMs,
                contextPctAtPost: pinnedPct,
                previousContextPct: pinnedPct,
                currentContextPct: 12,
                heartbeatAgeMs: freshHeartbeatMs
            ),
            .contextBelowThreshold
        )
    }

    /// Absent signal is not evidence of a wedge. A session that has taken no
    /// turn yet reports nothing, and "nothing" must not be read as "flat".
    func testMissingContextReadingDoesNotRotate() {
        XCTAssertEqual(
            decide(
                elapsedSincePostMs: pastGraceMs,
                contextPctAtPost: pinnedPct,
                previousContextPct: pinnedPct,
                currentContextPct: nil,
                heartbeatAgeMs: freshHeartbeatMs
            ),
            .noContextReading
        )
    }

    // MARK: - Condition 4: heartbeat

    /// A dead session is a separate failure with a separate fix. Rotating it
    /// here would respawn into whatever killed the first one and hide the
    /// death behind a rotation.
    func testStaleHeartbeatDoesNotRotate() {
        XCTAssertEqual(
            decide(
                elapsedSincePostMs: pastGraceMs,
                contextPctAtPost: pinnedPct,
                previousContextPct: pinnedPct,
                currentContextPct: pinnedPct,
                heartbeatAgeMs: staleHeartbeatMs
            ),
            .heartbeatStale
        )
    }

    func testMissingWorkerRowDoesNotRotate() {
        XCTAssertEqual(
            decide(
                elapsedSincePostMs: pastGraceMs,
                contextPctAtPost: pinnedPct,
                previousContextPct: pinnedPct,
                currentContextPct: pinnedPct,
                heartbeatAgeMs: nil
            ),
            .heartbeatStale
        )
    }

    // MARK: - End-to-end through tick()

    /// The wiring: a sidecar crosses its threshold, the monitor posts
    /// `rotate_me` and latches, nobody ever completes the event, and ten
    /// minutes later a later tick rotates it anyway. Asserted on the spawner,
    /// which is the only observable a rotation actually reaches.
    func testTickForceRotatesAWedgedSidecarAfterGracePeriod() async throws {
        let harness = try Harness(self)
        try await harness.lifecycle.spawn(harness.sidecar)
        do { let n = await harness.spawnCount(); XCTAssertEqual(n, 1) }

        // Pinned above threshold, heartbeating. First tick posts rotate_me.
        try harness.setWorker(contextTokens: 170_000, heartbeatAgeMs: 5_000)
        await harness.lifecycle.tick()
        XCTAssertEqual(try harness.pendingRotateMeCount(), 1, "first tick must post rotate_me")
        do { let n = await harness.spawnCount(); XCTAssertEqual(n, 1, "posting is not rotating") }

        // Nothing completes the event. The reading stays exactly where it was.
        await harness.lifecycle.tick()
        do { let n = await harness.spawnCount(); XCTAssertEqual(n, 1, "still inside the grace period") }
        XCTAssertEqual(try harness.pendingRotateMeCount(), 1, "the latch must suppress a duplicate post")

        harness.advance(by: SidecarLifecycle.rotateGraceSeconds + 1)
        try harness.setWorker(contextTokens: 170_000, heartbeatAgeMs: 5_000)
        await harness.lifecycle.tick()

        do { let n = await harness.spawnCount(); XCTAssertEqual(n, 2, "past grace, pinned, and heartbeating — tick must rotate") }
        do { let n = await harness.terminateCount(); XCTAssertEqual(n, 1, "the wedged session must be stood down") }
    }

    /// Same setup, same elapsed time, but the sidecar's context keeps moving.
    /// The latch alone must not be enough to end its session.
    func testTickLeavesABusyButProgressingSidecarAlone() async throws {
        let harness = try Harness(self)
        try await harness.lifecycle.spawn(harness.sidecar)

        try harness.setWorker(contextTokens: 170_000, heartbeatAgeMs: 5_000)
        await harness.lifecycle.tick()
        XCTAssertEqual(try harness.pendingRotateMeCount(), 1)

        harness.advance(by: SidecarLifecycle.rotateGraceSeconds + 1)
        // Climbing: 85% → 90% of the 200K window across two samples.
        try harness.setWorker(contextTokens: 178_000, heartbeatAgeMs: 5_000)
        await harness.lifecycle.tick()
        try harness.setWorker(contextTokens: 186_000, heartbeatAgeMs: 5_000)
        await harness.lifecycle.tick()

        do { let n = await harness.spawnCount(); XCTAssertEqual(n, 1, "a session still taking turns must not be rotated out from under itself") }
        do { let n = await harness.terminateCount(); XCTAssertEqual(n, 0) }
    }

    /// A rotation that DID complete leaves the fresh session below threshold.
    /// `spawn` clears the latch on that path, so there is nothing outstanding
    /// for the fallback to act on — and the fallback must not invent one.
    func testTickDoesNotRotateWhenContextDroppedAfterCompletion() async throws {
        let harness = try Harness(self)
        try await harness.lifecycle.spawn(harness.sidecar)

        try harness.setWorker(contextTokens: 170_000, heartbeatAgeMs: 5_000)
        await harness.lifecycle.tick()

        harness.advance(by: SidecarLifecycle.rotateGraceSeconds + 1)
        try harness.setWorker(contextTokens: 20_000, heartbeatAgeMs: 5_000)
        await harness.lifecycle.tick()

        do { let n = await harness.spawnCount(); XCTAssertEqual(n, 1) }
        do { let n = await harness.terminateCount(); XCTAssertEqual(n, 0) }
    }

    /// A session that stopped heartbeating is dead, not wedged. Rotating it
    /// would respawn into the same failure and log it as a routine rotation.
    func testTickDoesNotRotateASilentSidecar() async throws {
        let harness = try Harness(self)
        try await harness.lifecycle.spawn(harness.sidecar)

        try harness.setWorker(contextTokens: 170_000, heartbeatAgeMs: 5_000)
        await harness.lifecycle.tick()

        harness.advance(by: SidecarLifecycle.rotateGraceSeconds + 1)
        try harness.setWorker(contextTokens: 170_000, heartbeatAgeMs: 10 * 60 * 1000)
        await harness.lifecycle.tick()

        do { let n = await harness.spawnCount(); XCTAssertEqual(n, 1) }
        do { let n = await harness.terminateCount(); XCTAssertEqual(n, 0) }
    }
}

// MARK: - Harness

/// A live `SidecarLifecycle` over a temp-file database, a stub spawner, and a
/// clock the test moves by hand.
///
/// The clock is what makes the grace period testable: the alternative is a
/// test-only setter for the latch, which would let the production path and the
/// tested path drift apart. Here the latch is written by the real `tick()`.
private final class Harness {
    let dbPool: DatabasePool
    let lifecycle: SidecarLifecycle
    let sidecar: Sidecar
    let sessionKey = "sidecar-memory-session"

    private let counts = Counts()
    private let clock = MutableClock()

    /// Spawn/terminate tallies. An actor because the stub spawner is
    /// `@Sendable` and runs off the test's thread.
    actor Counts {
        private(set) var spawns = 0
        private(set) var terminates = 0
        func recordSpawn() { spawns += 1 }
        func recordTerminate() { terminates += 1 }
    }

    /// `Date()` under test control. `NSLock` rather than an actor because
    /// `SidecarLifecycle`'s clock is a synchronous `@Sendable () -> Date`.
    final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 0
        private let base = Date(timeIntervalSince1970: 1_750_000_000)
        func advance(by seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            offset += seconds
        }
        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            return base.addingTimeInterval(offset)
        }
    }

    init(_ test: XCTestCase) throws {
        SidecarRegistry.shared.reset()

        let tmpDir = NSTemporaryDirectory() + "sonata-wedge-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        test.addTeardownBlock {
            SidecarRegistry.shared.reset()
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        // `spawn` refuses a sidecar with no SKILL.md, by design — so the test
        // needs a real one on disk.
        let skillPath = tmpDir + "/SKILL.md"
        FileManager.default.createFile(atPath: skillPath, contents: Data("# test sidecar\n".utf8))

        dbPool = try DatabasePool(path: tmpDir + "/test.sqlite")
        try dbPool.write { db in try createSchema(in: db) }

        sidecar = Sidecar(
            name: "memory",
            skillPath: skillPath,
            eventTypes: ["memory_request"]
        )
        try SidecarRegistry.shared.register(sidecar)

        let key = sessionKey
        let counts = self.counts
        let clock = self.clock
        lifecycle = SidecarLifecycle(
            dbPool: dbPool,
            logger: Logger(label: "test.sidecar.wedge"),
            spawner: { _ in
                await counts.recordSpawn()
                return SidecarSessionHandle(sessionKey: key) {
                    await counts.recordTerminate()
                }
            },
            now: { clock.now() }
        )
    }

    func advance(by seconds: TimeInterval) { clock.advance(by: seconds) }
    func spawnCount() async -> Int { await counts.spawns }
    func terminateCount() async -> Int { await counts.terminates }

    /// Upsert the sidecar's worker row. Heartbeat is expressed as an age so
    /// the caller doesn't have to reason about the mutable clock's absolute
    /// value. `currentEventId` stays NULL so `rotate`'s drain returns at once —
    /// the drain sleeps on the real clock and is not what these tests are for.
    func setWorker(contextTokens: Int64, heartbeatAgeMs: Int64) throws {
        let heartbeat = Int64(clock.now().timeIntervalSince1970 * 1000) - heartbeatAgeMs
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO workers (workerId, sessionLabel, status, lastHeartbeat, registeredAt, currentContextTokens)
                VALUES (?, 'sidecar-memory', 'idle', ?, ?, ?)
                ON CONFLICT(workerId) DO UPDATE SET
                    lastHeartbeat = excluded.lastHeartbeat,
                    currentContextTokens = excluded.currentContextTokens
            """, arguments: [sessionKey, heartbeat, heartbeat, contextTokens])
        }
    }

    func pendingRotateMeCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workerEvents WHERE type = 'rotate_me'") ?? 0
        }
    }
}
