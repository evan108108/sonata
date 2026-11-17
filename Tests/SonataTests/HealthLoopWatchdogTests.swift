import XCTest
import GRDB
@testable import Sonata

/// HealthMonitor stall watchdog (2026-11-17). After the 13:27Z local relaunch
/// the monitor loop's first cycle suspended forever and ran zero cycles for
/// ~40 min, with every per-cycle sweep silently off. These tests never run the
/// real monitorLoop: its GhostWorkerReaper would SIGTERM the host's live
/// workers. They drive the same generation + watchdog machinery with a
/// stand-in loop.
final class HealthLoopWatchdogTests: XCTestCase {

    // MARK: - HealthCycleProgress

    func testStallNamesTheStuckStepOnlyPastThreshold() {
        let p = HealthCycleProgress()
        let t0 = Date()
        let gen = p.newGeneration()
        p.begin(gen, at: t0)
        p.mark(gen, "check:searchAndEmbeddings", at: t0.addingTimeInterval(5))

        XCTAssertNil(p.stall(now: t0.addingTimeInterval(60), threshold: 600), "a young cycle is not a stall")

        let s = p.stall(now: t0.addingTimeInterval(700), threshold: 600)
        XCTAssertEqual(s?.step, "check:searchAndEmbeddings")
        XCTAssertEqual(s?.cycleSeconds, 700)
        XCTAssertEqual(s?.stepSeconds, 695)
        XCTAssertEqual(s?.generation, gen)
    }

    func testSleepBetweenCyclesIsNeverAStall() {
        let p = HealthCycleProgress()
        let t0 = Date()
        let gen = p.newGeneration()
        p.begin(gen, at: t0)
        p.end(gen)
        XCTAssertNil(p.stall(now: t0.addingTimeInterval(3600), threshold: 600), "an idle loop between cycles")
        XCTAssertEqual(p.completedCycles, 1)

        // Control: the next cycle that never ends does stall.
        p.begin(gen, at: t0.addingTimeInterval(3600))
        XCTAssertNotNil(p.stall(now: t0.addingTimeInterval(4300), threshold: 600))
    }

    func testAbandonedGenerationCannotOverwriteItsReplacement() {
        let p = HealthCycleProgress()
        let t0 = Date()
        let old = p.newGeneration()
        p.begin(old, at: t0)
        let fresh = p.newGeneration()
        XCTAssertNil(p.stall(now: t0.addingTimeInterval(3600), threshold: 600), "a new generation clears the stalled cycle")

        // The old loop wakes up and keeps marking: ignored.
        p.begin(old, at: t0)
        p.mark(old, "zombie", at: t0)
        p.end(old)
        XCTAssertNil(p.stall(now: t0.addingTimeInterval(3600), threshold: 600))
        XCTAssertEqual(p.completedCycles, 0, "the stale generation's end is not counted")

        // Control: the current generation's marks still land.
        p.begin(fresh, at: t0)
        p.mark(fresh, "check:database", at: t0)
        XCTAssertEqual(p.stall(now: t0.addingTimeInterval(3600), threshold: 600)?.step, "check:database")
    }

    // MARK: - Watchdog + restart

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    /// Records which generations ran, and makes the first one hang forever on
    /// a continuation that is never resumed, ignoring cancellation, the way
    /// the 13:27Z cycle did.
    private actor LoopScript {
        private(set) var started: [Int] = []
        func run(_ gen: Int) -> Bool { started.append(gen); return started.count == 1 }
    }

    func testWatchdogRestartsAStalledLoopAndNamesTheStep() async throws {
        let monitor = HealthMonitor(dbPool: try makePool())
        let script = LoopScript()
        await monitor.superviseForTesting(loop: { m, gen in
            let hang = await script.run(gen)
            m.progress.begin(gen)
            if hang {
                m.progress.mark(gen, "check:stuck-here")
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            }
            m.progress.mark(gen, "check:database")
            m.progress.end(gen)
        }, watchdogInterval: 0.05, stallThreshold: 0.2)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, monitor.progress.completedCycles == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let recoveries = await monitor.stallRecoveries
        let started = await script.started
        await monitor.shutdown()

        XCTAssertEqual(recoveries.count, 1, "one stall, one recovery")
        XCTAssertEqual(recoveries.first?.step, "check:stuck-here", "the alert names where the cycle is stuck")
        XCTAssertEqual(started.count, 2, "the loop was restarted under a new generation")
        XCTAssertEqual(monitor.progress.completedCycles, 1, "the replacement loop completed a cycle")
    }

    func testWatchdogLeavesAHealthyLoopAlone() async throws {
        let monitor = HealthMonitor(dbPool: try makePool())
        let script = LoopScript()
        await monitor.superviseForTesting(loop: { m, gen in
            _ = await script.run(gen)
            while !Task.isCancelled {
                m.progress.begin(gen)
                m.progress.mark(gen, "check:database")
                m.progress.end(gen)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }, watchdogInterval: 0.05, stallThreshold: 0.2)

        try await Task.sleep(for: .milliseconds(800))
        let recoveries = await monitor.stallRecoveries
        let started = await script.started
        let cycles = monitor.progress.completedCycles
        await monitor.shutdown()

        XCTAssertTrue(recoveries.isEmpty, "a loop that keeps completing cycles is never restarted")
        XCTAssertEqual(started.count, 1)
        XCTAssertGreaterThan(cycles, 5, "control: the loop really was cycling under the watchdog")
    }
}
