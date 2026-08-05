import XCTest
@testable import Sonata

// Regression tests for OffPoolProcess — the shared "run a subprocess from an async
// context" helper introduced for SCT-4.
//
// Background: the 2026-07-18 NIOAsyncWriter deinit traps were pool exhaustion, not an
// upstream swift-nio race (we were already on 2.97.1). SchedulerActor.runShellCommand
// and PluginManager.tailPluginPipe were fixed individually; this helper is the reusable
// form, and the remaining async call sites (GhostWorkerReaper's once-a-minute ps/pgrep
// sweep, BackupManager's sqlite3+gzip, PluginManager.install's tar) now route through it.
//
// The two defects it has to stay immune to are the same two that produced the crash:
// blocking a cooperative thread, and deadlocking on a pipe larger than the buffer.
final class OffPoolProcessTests: XCTestCase {

    /// The load-bearing one. 512KB of output is ~8x the 64KB pipe buffer. A
    /// wait-then-read implementation deadlocks here: the child blocks writing while we
    /// block waiting for it to exit. Asserts the output is COMPLETE, not merely non-empty
    /// — a truncated read would still "pass" a non-empty check.
    func testLargeOutputExceedingPipeBufferIsCapturedInFull() async throws {
        let lineCount = 20_000
        let outcome = await OffPoolProcess.run(
            "/bin/sh",
            ["-c", "for i in $(seq 1 \(lineCount)); do echo \"line-$i-padding-padding-padding\"; done"]
        )

        let unwrapped = try XCTUnwrap(outcome, "process should have spawned")
        XCTAssertEqual(unwrapped.status, 0)

        let lines = unwrapped.text.split(separator: "\n")
        XCTAssertEqual(lines.count, lineCount, "output was truncated — pipe was not fully drained")
        XCTAssertEqual(lines.first, "line-1-padding-padding-padding")
        XCTAssertEqual(lines.last, "line-\(lineCount)-padding-padding-padding")
    }

    /// The whole point of the helper: a blocking child must not consume a cooperative
    /// thread. Swift's pool is roughly one thread per core, so we launch comfortably more
    /// concurrent sleepers than that and require them to finish in about the time of ONE
    /// sleep. If the blocking wait ran on the cooperative pool these would serialise into
    /// batches and blow the deadline.
    func testConcurrentBlockingChildrenDoNotSerialiseOnTheCooperativePool() async throws {
        let sleepers = max(ProcessInfo.processInfo.activeProcessorCount * 3, 24)
        let start = Date()

        await withTaskGroup(of: Int32?.self) { group in
            for _ in 0..<sleepers {
                group.addTask { await OffPoolProcess.run("/bin/sleep", ["1"])?.status }
            }
            for await status in group {
                XCTAssertEqual(status, 0)
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 8.0,
            "\(sleepers) concurrent 1s sleeps took \(elapsed)s — they are serialising, "
            + "which means the blocking wait is back on a constrained pool"
        )
    }

    /// A child that runs and fails is an Outcome with a non-zero status, NOT nil. Callers
    /// distinguish "could not spawn" from "ran and failed", so collapsing the two would
    /// silently turn a failed backup into a spawn error in the logs.
    func testNonZeroExitIsReportedAsOutcomeNotSpawnFailure() async throws {
        let outcome = await OffPoolProcess.run("/bin/sh", ["-c", "exit 3"])
        let unwrapped = try XCTUnwrap(outcome, "a child that exits non-zero still spawned")
        XCTAssertEqual(unwrapped.status, 3)
    }

    /// Only an actual spawn failure yields nil.
    func testUnspawnableExecutableReturnsNil() async {
        let outcome = await OffPoolProcess.run("/nonexistent/definitely-not-a-binary", [])
        XCTAssertNil(outcome)
    }

    /// stderr is discarded rather than interleaved into stdout — GhostWorkerReaper parses
    /// stdout positionally, so a stray stderr line would corrupt pid/workerId parsing.
    func testStderrIsNotMixedIntoStdout() async throws {
        let outcome = await OffPoolProcess.run(
            "/bin/sh",
            ["-c", "echo to-stdout; echo to-stderr >&2"]
        )
        let unwrapped = try XCTUnwrap(outcome)
        XCTAssertEqual(unwrapped.text.trimmingCharacters(in: .whitespacesAndNewlines), "to-stdout")
    }
}
