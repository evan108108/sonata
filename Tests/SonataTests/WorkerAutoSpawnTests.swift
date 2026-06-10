import XCTest
import GRDB
@testable import Sonata

/// Tests for the four-part WorkerManager auto-spawn fix shipped after the
/// 2026-05-18 pool-stuck-at-1/2 incident.
///
/// Plan doc: /Users/evan/memory/claude/documents/plans/worker-auto-spawn-stuck-2026-05-18.md
///
/// Scope:
///   - Fix 1: WorkerManager.computePoolMaintainPlan is status-aware.
///   - Fix 2: WorkerCoordinator.sessionJSONLExists picks --resume vs --session-id.
///   - Fix 3: WorkerCoordinator.shouldDisableAfterAttempts bounds the restart loop.
///   - Fix 4: HealthMonitor.worker_pool check goes unhealthy when stuck past grace.
///
/// All four assertions are on PURE helpers so we don't have to instantiate
/// real Worker/AppKit views in the test runner.
final class WorkerAutoSpawnTests: XCTestCase {

    // MARK: - Fix 1: computePoolMaintainPlan is status-aware

    /// 2026-06-10 semantics: an empty slot is treated as user-removed, not
    /// as a hole to refill. Boot-time population is `spawnDefaultWorkers`'s
    /// job; `maintainPoolSize` only heals stale `.offline` workers.
    func test_maintainPlan_emptyPool_noOp() {
        let plan = WorkerManager.computePoolMaintainPlan(target: 2, workers: [])
        XCTAssertTrue(plan.toSpawn.isEmpty,
            "empty pool must not auto-spawn — refilling stomps explicit user removals")
        XCTAssertTrue(plan.toDisplace.isEmpty)
    }

    /// User-removal regression: removing a slot via the Workers UI deletes
    /// the Worker from the array entirely. The next pollHealth tick must
    /// leave the gap alone instead of respawning it.
    func test_maintainPlan_userRemovedSlot_staysGone() {
        let workers = [
            WorkerManager.WorkerSlotInfo(id: "w3", label: "sona-worker-3", status: .idle),
            // slots 1 and 2 absent — user clicked Remove on both
        ]
        let plan = WorkerManager.computePoolMaintainPlan(target: 3, workers: workers)
        XCTAssertTrue(plan.toSpawn.isEmpty,
            "removed slots must NOT come back from maintainPoolSize")
        XCTAssertTrue(plan.toDisplace.isEmpty)
    }

    func test_maintainPlan_fullIdlePool_noOp() {
        let workers = [
            WorkerManager.WorkerSlotInfo(id: "w1", label: "sona-worker-1", status: .idle),
            WorkerManager.WorkerSlotInfo(id: "w2", label: "sona-worker-2", status: .idle),
        ]
        let plan = WorkerManager.computePoolMaintainPlan(target: 2, workers: workers)
        XCTAssertTrue(plan.toSpawn.isEmpty)
        XCTAssertTrue(plan.toDisplace.isEmpty)
    }

    /// 2026-05-18 incident — primary regression test. An `.offline` worker
    /// previously occupied its slot and the pool stalled at 1/2.
    func test_maintainPlan_offlineWorker_isDisplacedAndSlotRespawned() {
        let workers = [
            WorkerManager.WorkerSlotInfo(id: "w1", label: "sona-worker-1", status: .idle),
            WorkerManager.WorkerSlotInfo(id: "w2-dead", label: "sona-worker-2", status: .offline),
        ]
        let plan = WorkerManager.computePoolMaintainPlan(target: 2, workers: workers)
        XCTAssertEqual(plan.toSpawn, ["sona-worker-2"])
        XCTAssertEqual(plan.toDisplace, ["w2-dead"])
    }

    /// In-flight starts (`.starting`, `.restarting`) still occupy the slot —
    /// otherwise pollHealth would double-spawn during normal startup.
    func test_maintainPlan_startingWorker_blocksSpawn() {
        let workers = [
            WorkerManager.WorkerSlotInfo(id: "w1", label: "sona-worker-1", status: .starting),
            WorkerManager.WorkerSlotInfo(id: "w2", label: "sona-worker-2", status: .restarting),
        ]
        let plan = WorkerManager.computePoolMaintainPlan(target: 2, workers: workers)
        XCTAssertTrue(plan.toSpawn.isEmpty)
        XCTAssertTrue(plan.toDisplace.isEmpty)
    }

    /// A `.draining` worker is mid-retirement; it still owns the slot until
    /// pollHealth removes it. The replacement is spawned by cycleWorker, not
    /// by maintainPoolSize, so we should NOT double-spawn here.
    func test_maintainPlan_drainingWorker_blocksSpawn() {
        let workers = [
            WorkerManager.WorkerSlotInfo(id: "w1", label: "sona-worker-1", status: .idle),
            WorkerManager.WorkerSlotInfo(id: "w2", label: "sona-worker-2", status: .draining),
        ]
        let plan = WorkerManager.computePoolMaintainPlan(target: 2, workers: workers)
        XCTAssertTrue(plan.toSpawn.isEmpty)
        XCTAssertTrue(plan.toDisplace.isEmpty)
    }

    func test_maintainPlan_target_zero_isNoOp() {
        let workers = [
            WorkerManager.WorkerSlotInfo(id: "w1", label: "sona-worker-1", status: .idle),
        ]
        let plan = WorkerManager.computePoolMaintainPlan(target: 0, workers: workers)
        XCTAssertTrue(plan.toSpawn.isEmpty)
        XCTAssertTrue(plan.toDisplace.isEmpty)
    }

    func test_maintainPlan_liveOccupantBeatsOfflineSibling() {
        // Both a live and dead worker share slot 1 (transient pollHealth state).
        // The slot is satisfied by the live worker; no displacement needed.
        let workers = [
            WorkerManager.WorkerSlotInfo(id: "w1-live", label: "sona-worker-1", status: .busy),
            WorkerManager.WorkerSlotInfo(id: "w1-dead", label: "sona-worker-1", status: .offline),
        ]
        let plan = WorkerManager.computePoolMaintainPlan(target: 1, workers: workers)
        XCTAssertTrue(plan.toSpawn.isEmpty)
        XCTAssertTrue(plan.toDisplace.isEmpty)
    }

    // MARK: - Fix 2: --resume vs --session-id by JSONL existence

    func test_sessionJSONLPath_matchesClaudeConvention() {
        let path = WorkerCoordinator.sessionJSONLPath(
            sessionId: "00000000-0000-0000-0000-000000000abc",
            cwd: "/Users/evan/.sonata/worker",
            home: "/Users/evan"
        )
        XCTAssertEqual(path,
            "/Users/evan/.claude/projects/-Users-evan--sonata-worker/00000000-0000-0000-0000-000000000abc.jsonl")
    }

    func test_sessionJSONLExists_falseWhenAbsent() {
        let tmpHome = NSTemporaryDirectory() + "sonata-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpHome) }
        let exists = WorkerCoordinator.sessionJSONLExists(
            sessionId: "nope",
            cwd: "/Users/evan/.sonata/worker",
            home: tmpHome
        )
        XCTAssertFalse(exists, "no JSONL on disk → use --session-id (fresh)")
    }

    func test_sessionJSONLExists_trueWhenPresent() throws {
        let tmpHome = NSTemporaryDirectory() + "sonata-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpHome) }
        let cwd = "/Users/evan/.sonata/worker"
        let sessionId = "deadbeef-0000-0000-0000-000000000001"
        let path = WorkerCoordinator.sessionJSONLPath(sessionId: sessionId, cwd: cwd, home: tmpHome)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())

        let exists = WorkerCoordinator.sessionJSONLExists(
            sessionId: sessionId,
            cwd: cwd,
            home: tmpHome
        )
        XCTAssertTrue(exists, "JSONL present → restart must use --resume to avoid 'session already in use'")
    }

    // MARK: - Fix 3: bound auto-restart attempts

    func test_restartBound_withinLimit_keepsRestarting() {
        XCTAssertFalse(WorkerCoordinator.shouldDisableAfterAttempts(attempts: 1, max: 3))
        XCTAssertFalse(WorkerCoordinator.shouldDisableAfterAttempts(attempts: 2, max: 3))
        XCTAssertFalse(WorkerCoordinator.shouldDisableAfterAttempts(attempts: 3, max: 3))
    }

    func test_restartBound_exceeded_disables() {
        XCTAssertTrue(WorkerCoordinator.shouldDisableAfterAttempts(attempts: 4, max: 3))
        XCTAssertTrue(WorkerCoordinator.shouldDisableAfterAttempts(attempts: 100, max: 3))
    }

    func test_cycleSettings_maxAutoRestarts_defaultIsThree() {
        // Clear any prior test-run value so we see the default branch.
        UserDefaults.standard.removeObject(forKey: "sonata.maxAutoRestarts")
        XCTAssertEqual(CycleSettings.shared.maxAutoRestarts, 3)
    }

    // MARK: - Fix 4: HealthMonitor worker_pool backstop

    func test_workerPool_healthy_whenAtTarget() async throws {
        let pool = try await makeInMemoryPool()
        let h = HealthMonitor(
            dbPool: pool,
            workerPoolStatus: { (target: 2, effective: 2) }
        )
        let result = await h.runWorkerPoolCheckForTesting()
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.healthy ?? false)
        XCTAssertEqual(result?.name, "worker_pool")
    }

    func test_workerPool_underTarget_withinGrace_stillHealthy() async throws {
        let pool = try await makeInMemoryPool()
        let h = HealthMonitor(
            dbPool: pool,
            workerPoolStatus: { (target: 2, effective: 1) }
        )
        // First detection — clock starts now.
        let result = await h.runWorkerPoolCheckForTesting()
        XCTAssertTrue(result?.healthy ?? false,
            "under-target for <5 min should NOT fire — auto-spawn gets a tick to recover")
    }

    func test_workerPool_underTarget_pastGrace_isUnhealthy() async throws {
        let pool = try await makeInMemoryPool()
        let h = HealthMonitor(
            dbPool: pool,
            workerPoolStatus: { (target: 2, effective: 1) }
        )
        // Prime the stuck-since clock 6 minutes in the past.
        await h.setPoolUnderTargetSinceForTesting(Date().addingTimeInterval(-360))
        let result = await h.runWorkerPoolCheckForTesting()
        XCTAssertEqual(result?.healthy, false,
            "under-target for >5 min must report unhealthy so the alert path fires")
        XCTAssertTrue(result?.message.contains("Pool below target") ?? false)
    }

    func test_workerPool_recovered_clearsStuckClock() async throws {
        let pool = try await makeInMemoryPool()
        let h = HealthMonitor(
            dbPool: pool,
            workerPoolStatus: { (target: 2, effective: 2) }
        )
        await h.setPoolUnderTargetSinceForTesting(Date().addingTimeInterval(-3600))
        let result = await h.runWorkerPoolCheckForTesting()
        XCTAssertTrue(result?.healthy ?? false)
        XCTAssertTrue(result?.message.hasPrefix("OK") ?? false)
    }

    func test_workerPool_noProvider_isSkipped() async throws {
        let pool = try await makeInMemoryPool()
        let h = HealthMonitor(dbPool: pool)  // workerPoolStatus nil
        let result = await h.runWorkerPoolCheckForTesting()
        XCTAssertNil(result, "no provider → check is silently skipped (test-harness mode)")
    }

    // MARK: - Helpers

    private func makeInMemoryPool() async throws -> DatabasePool {
        // HealthMonitor's init requires a DatabasePool; we don't need to
        // exercise the SQL paths for these tests, so any pool will do.
        // MCPTestHarness builds one with the full schema applied.
        let h = try MCPTestHarness.make()
        // Note: deliberately not tearing down the harness — the pool needs
        // to outlive HealthMonitor. SwiftPM tears down the process after.
        return h.dbPool
    }
}
