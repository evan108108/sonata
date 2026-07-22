import XCTest
@testable import Sonata

// Unit tests for the HTTP liveness watchdog that supervises the Hummingbird
// server (SonataApp.swift). The watchdog exists because the 2026-07-17
// ServiceGroup-based supervisor cannot see the failure we have actually hit
// twice: the listener binds, logs "Server started and listening", then refuses
// every connection while `runService()` never returns. On 2026-07-21 that ran
// 11 minutes on Evan's Mac until a manual quit+relaunch.
//
// These exercise the probe loop against a port nobody is serving — no real
// Application is started. What they pin down is the tolerance policy, which is
// the part that would do damage if it drifted: a watchdog that trips too eagerly
// bounces a healthy server, and one that never trips is the bug we just fixed.
final class HTTPLivenessWatchdogTests: XCTestCase {

    /// A port in the ephemeral range that nothing should be serving. Probes
    /// against it fail immediately with connection-refused — the same signature
    /// the real incident produced.
    private let deadPort = 59_237

    func testThrowsLivenessLostAfterConsecutiveFailures() async {
        do {
            try await httpLivenessWatchdog(
                port: deadPort,
                graceSeconds: 0,
                probeInterval: 0.01,
                failuresBeforeRestart: 3
            )
            XCTFail("watchdog should have thrown once the probe budget was spent")
        } catch let error as HTTPServerSupervisorError {
            guard case .livenessLost(let count) = error else {
                return XCTFail("expected .livenessLost, got \(error)")
            }
            XCTAssertEqual(count, 3, "should trip exactly at the configured threshold, not before")
        } catch {
            XCTFail("expected HTTPServerSupervisorError, got \(error)")
        }
    }

    /// The grace period is what keeps a slow boot from being mistaken for a
    /// dead server: the real server takes a moment to bind after the task
    /// starts, and probing through that window would restart every launch.
    func testHonorsGracePeriodBeforeFirstProbe() async {
        let start = Date()
        do {
            try await httpLivenessWatchdog(
                port: deadPort,
                graceSeconds: 0.4,
                probeInterval: 0.01,
                failuresBeforeRestart: 1
            )
            XCTFail("watchdog should have thrown against a dead port")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertGreaterThanOrEqual(
                elapsed, 0.4,
                "watchdog probed before the grace period elapsed — a slow bind would be restarted"
            )
        }
    }

    /// Cancellation must unwind quietly. The supervisor cancels this task on
    /// every normal shutdown; a watchdog that threw `livenessLost` on the way
    /// out would log a phantom restart on each clean quit.
    func testCancellationDoesNotReportLivenessLost() async {
        let task = Task {
            try await httpLivenessWatchdog(
                port: deadPort,
                graceSeconds: 30,
                probeInterval: 0.01,
                failuresBeforeRestart: 1
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            try await task.value
        } catch is CancellationError {
            // expected — sleeping in the grace window unwinds as cancellation
        } catch let error as HTTPServerSupervisorError {
            XCTFail("cancellation surfaced as \(error) — clean shutdown would look like a wedge")
        } catch {
            XCTFail("unexpected error on cancellation: \(error)")
        }
    }
}
