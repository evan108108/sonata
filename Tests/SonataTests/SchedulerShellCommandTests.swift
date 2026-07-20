import XCTest
@testable import Sonata

// Regression tests for the two defects in SchedulerActor.runShellCommand that produced
// the 2026-07-18 NIOAsyncWriter deinit crashes on .17.
//
// 1. COOPERATIVE-POOL STARVATION / SELF-DEADLOCK. The old implementation called
//    process.waitUntilExit() — a blocking wait — from inside an async function, i.e. on
//    one of Swift's cooperative pool threads (one per core). Concurrent long-running
//    shell jobs therefore consumed the whole pool for up to the full 300s timeout.
//    Sonata's own HTTP server is served from that same pool, so a `mem task add` job
//    whose curl hits localhost:3211 waited on a thread its sibling jobs were holding.
//
// 2. PIPE DEADLOCK ON LARGE OUTPUT. readDataToEndOfFile() was called AFTER
//    waitUntilExit(). Nothing drained the pipe while the child ran, so any job emitting
//    more than the ~64KB pipe buffer blocked forever writing, while we blocked forever
//    waiting for it to exit. Neither side could advance.
//
// Both tests below HANG on the old implementation, which is what makes them real
// regression tests rather than assertions that merely restate the new code.
final class SchedulerShellCommandTests: XCTestCase {

    /// Defect #2. 512KB of output is 8x the pipe buffer; the old read-after-wait
    /// ordering deadlocks here. Asserts the output is not merely non-empty but COMPLETE.
    func testLargeOutputExceedingPipeBufferIsCapturedInFull() async throws {
        let lineCount = 20_000
        let output = try await SchedulerActor.runShellCommand(
            "for i in $(seq 1 \(lineCount)); do echo \"line-$i-padding-padding-padding\"; done"
        )

        let lines = output.split(separator: "\n")
        XCTAssertEqual(lines.count, lineCount, "every line must survive; a truncated read is silent data loss")
        XCTAssertGreaterThan(output.utf8.count, 64 * 1024, "test is only meaningful above the pipe buffer")
        XCTAssertEqual(lines.first, "line-1-padding-padding-padding")
        XCTAssertEqual(lines.last, "line-\(lineCount)-padding-padding-padding")
    }

    /// Defect #1. Runs far more concurrent jobs than the machine has cores. If each one
    /// blocks a cooperative thread, these serialize into core-count-sized batches; with
    /// termination-handler completion they overlap and finish in roughly one sleep.
    func testConcurrentJobsDoNotSerializeOnCooperativeThreads() async throws {
        let jobCount = 32
        let sleepSeconds = 1.0
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        // Blocking would need at least ceil(32/cores) sequential rounds. Land safely
        // between "fully overlapped" and that serialized floor.
        let serializedFloor = (Double(jobCount) / cores).rounded(.up) * sleepSeconds

        let start = Date()
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<jobCount {
                group.addTask { try await SchedulerActor.runShellCommand("sleep \(sleepSeconds); echo done") }
            }
            for try await result in group {
                XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "done")
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, serializedFloor,
                          "\(jobCount) concurrent jobs took \(elapsed)s; serialized floor on \(Int(cores)) cores is \(serializedFloor)s — threads are being blocked")
    }

    /// The async path must not swallow the HTTP-server-starving case's sibling concern:
    /// while shell jobs run, unrelated async work still has to make progress.
    func testUnrelatedAsyncWorkProgressesWhileShellJobsRun() async throws {
        async let shellJobs: Void = withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<32 {
                group.addTask { try await SchedulerActor.runShellCommand("sleep 1; echo done") }
            }
            for try await _ in group {}
        }

        // Independent work, started after the jobs are in flight.
        var ticks = 0
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 50_000_000)
            ticks += 1
        }
        XCTAssertEqual(ticks, 5, "unrelated async work must not be starved by shell jobs")

        try await shellJobs
    }

    func testSuccessfulCommandReturnsStdout() async throws {
        let output = try await SchedulerActor.runShellCommand("echo hello-sonata")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "hello-sonata")
    }

    /// A non-zero exit must still surface the captured output — the scheduler logs it,
    /// and an empty message is how a failing job becomes unattributable.
    func testFailingCommandThrowsWithExitCodeAndOutput() async throws {
        do {
            _ = try await SchedulerActor.runShellCommand("echo failing-output; exit 3")
            XCTFail("expected shellFailed")
        } catch let SchedulerError.shellFailed(exitCode, output) {
            XCTAssertEqual(exitCode, 3)
            XCTAssertTrue(output.contains("failing-output"), "output was: \(output)")
        }
    }

    /// stderr is merged into the same pipe; a job that only writes to stderr must not
    /// come back blank.
    func testStderrIsCaptured() async throws {
        do {
            _ = try await SchedulerActor.runShellCommand("echo to-stderr >&2; exit 1")
            XCTFail("expected shellFailed")
        } catch let SchedulerError.shellFailed(_, output) {
            XCTAssertTrue(output.contains("to-stderr"), "output was: \(output)")
        }
    }

    /// A job that backgrounds a long-lived grandchild keeps the write end of the pipe
    /// open past its own exit. EOF never arrives, so completion must fall back to the
    /// post-exit grace period rather than stranding the continuation forever.
    func testBackgroundedGrandchildHoldingPipeDoesNotStrandTheCall() async throws {
        let start = Date()
        let output = try await SchedulerActor.runShellCommand("(sleep 30 &) ; echo parent-done")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(output.contains("parent-done"), "output was: \(output)")
        XCTAssertLessThan(elapsed, 10, "must complete on the grace path, not wait for the grandchild")
    }
}
