import XCTest
@testable import Sonata

// Regression tests for the startup-loader's stuck-'starting' plugin recovery
// (Sources/StartupGate.swift). Pins the fix for the bug where a plugin wedged
// in status='starting' during cold start fell through both the failed-recovery
// and all-running branches, so the loader spun to its 30s timeout and the user
// had to manually disable→enable the plugin in the Plugins tab.
//
// These exercise the pure decision helper `stuckStartingToRecover`; the HTTP
// toggle itself (recoverStuckPlugins → /disable + /enable) is the same proven
// path the failed-plugin recovery already uses.
final class StuckStartingRecoveryTests: XCTestCase {

    private let grace: TimeInterval = 18

    func testPluginWithinGraceIsNotRecovered() {
        let t0 = Date()
        var firstSeen: [String: Date] = [:]
        // First sighting — records the timestamp, recovers nothing yet.
        let r0 = stuckStartingToRecover(
            startingNames: ["sonar"], firstSeenStarting: &firstSeen,
            recoveredStarting: [], now: t0, grace: grace)
        XCTAssertEqual(r0, [])
        XCTAssertEqual(firstSeen["sonar"], t0)

        // Still inside the grace window (10s < 18s) — leave the healthy-but-slow
        // boot alone.
        let r1 = stuckStartingToRecover(
            startingNames: ["sonar"], firstSeenStarting: &firstSeen,
            recoveredStarting: [], now: t0.addingTimeInterval(10), grace: grace)
        XCTAssertEqual(r1, [])
    }

    func testPluginPastGraceIsRecovered() {
        let t0 = Date()
        var firstSeen: [String: Date] = ["sonar": t0]
        let recovered = stuckStartingToRecover(
            startingNames: ["sonar"], firstSeenStarting: &firstSeen,
            recoveredStarting: [], now: t0.addingTimeInterval(20), grace: grace)
        XCTAssertEqual(recovered, ["sonar"])
    }

    func testGraceClockStartsAtFirstSighting_NotLoopStart() {
        // A plugin that only enters 'starting' late (sequential boot) must get
        // its full grace window from when it was first seen — not be toggled
        // immediately just because the loader has already been running a while.
        let loopStart = Date()
        var firstSeen: [String: Date] = [:]

        // Plugin appears 'starting' for the first time 25s into the run.
        let lateAppearance = loopStart.addingTimeInterval(25)
        let r0 = stuckStartingToRecover(
            startingNames: ["prstar"], firstSeenStarting: &firstSeen,
            recoveredStarting: [], now: lateAppearance, grace: grace)
        XCTAssertEqual(r0, [], "a freshly-seen 'starting' plugin must not be toggled on sight")

        // 10s after first sighting — still within grace.
        let r1 = stuckStartingToRecover(
            startingNames: ["prstar"], firstSeenStarting: &firstSeen,
            recoveredStarting: [], now: lateAppearance.addingTimeInterval(10), grace: grace)
        XCTAssertEqual(r1, [])

        // 19s after first sighting — now past grace.
        let r2 = stuckStartingToRecover(
            startingNames: ["prstar"], firstSeenStarting: &firstSeen,
            recoveredStarting: [], now: lateAppearance.addingTimeInterval(19), grace: grace)
        XCTAssertEqual(r2, ["prstar"])
    }

    func testAlreadyRecoveredPluginIsNotToggledAgain() {
        let t0 = Date()
        var firstSeen: [String: Date] = ["sonar": t0]
        // Even well past grace, a plugin already in the recovered set is skipped
        // (the once-only guard prevents toggle storms while it re-boots).
        let recovered = stuckStartingToRecover(
            startingNames: ["sonar"], firstSeenStarting: &firstSeen,
            recoveredStarting: ["sonar"], now: t0.addingTimeInterval(60), grace: grace)
        XCTAssertEqual(recovered, [])
    }

    func testOnlyStuckPluginsAmongAMixAreReturned() {
        let t0 = Date()
        // sonar seen long ago (stuck), studio seen just now (fresh).
        var firstSeen: [String: Date] = ["sonar": t0]
        let now = t0.addingTimeInterval(20)
        let recovered = stuckStartingToRecover(
            startingNames: ["sonar", "sonata-studio"], firstSeenStarting: &firstSeen,
            recoveredStarting: [], now: now, grace: grace)
        XCTAssertEqual(recovered, ["sonar"])
        // studio's first sighting was recorded this tick.
        XCTAssertEqual(firstSeen["sonata-studio"], now)
    }
}
