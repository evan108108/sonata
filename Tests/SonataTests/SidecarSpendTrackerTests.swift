import XCTest
@testable import Sonata

// Tests for the sidecar spend ledger and its auto-throttle.
//
// The two things most worth pinning down here are the ones that would fail
// silently in production: spend that never ages out of the rolling window (a
// sidecar would throttle itself permanently after one busy week), and a
// throttle callback that re-fires on every recorded event (Task D's handler
// would be asked to drop a tier hundreds of times in a row).
//
// The clock is injected rather than real, so window aging is exercised by
// moving time forward a week instead of waiting for one.
final class SidecarSpendTrackerTests: XCTestCase {

    /// Controllable clock. A plain `var` captured in a `@Sendable` closure will
    /// not compile, so the mutable instant lives behind a lock.
    private final class TestClock: @unchecked Sendable {
        private var instant: Int64
        private let lock = NSLock()

        init(_ start: Int64) { self.instant = start }

        var nowMs: Int64 {
            lock.lock(); defer { lock.unlock() }
            return instant
        }

        func advance(hours: Int) {
            lock.lock(); defer { lock.unlock() }
            instant += Int64(hours) * 60 * 60 * 1000
        }
    }

    /// Records what the throttle callback was told, in order.
    private final class ThrottleLog: @unchecked Sendable {
        private var entries: [(String, ThrottleAction)] = []
        private let lock = NSLock()

        func append(_ sidecar: String, _ action: ThrottleAction) {
            lock.lock(); defer { lock.unlock() }
            entries.append((sidecar, action))
        }

        var actions: [ThrottleAction] {
            lock.lock(); defer { lock.unlock() }
            return entries.map { $0.1 }
        }
    }

    private let base: Int64 = 1_700_000_000_000
    private let sidecarName = "memory"

    /// 20% of 25M = 5M tokens, so these tests can talk in round numbers.
    private var allowance: Int { SidecarSpendTracker.Defaults.weeklyCapTokens }

    override func setUp() {
        super.setUp()
        SidecarRegistry.shared.reset()
        try? SidecarRegistry.shared.register(
            Sidecar(name: sidecarName, skillPath: "/nonexistent/SKILL.md", eventTypes: ["memory_request"])
        )
    }

    override func tearDown() {
        SidecarRegistry.shared.reset()
        super.tearDown()
    }

    private func makeTracker(
        clock: TestClock,
        onThrottle: (@Sendable (String, ThrottleAction) async -> Void)? = nil
    ) -> SidecarSpendTracker {
        SidecarSpendTracker(applyThrottle: onThrottle, now: { clock.nowMs })
    }

    // MARK: - Recording

    func testWindowSpendSumsInputAndOutput() async {
        let clock = TestClock(base)
        let tracker = makeTracker(clock: clock)

        await tracker.record(sidecar: sidecarName, inputTokens: 1_000, outputTokens: 250, at: base)
        await tracker.record(sidecar: sidecarName, inputTokens: 400, outputTokens: 100, at: base)

        let spend = await tracker.windowSpend(sidecar: sidecarName)
        XCTAssertEqual(spend, 1_750, "input and output tokens both count against the budget")
    }

    func testUnknownSidecarHasZeroSpend() async {
        let tracker = makeTracker(clock: TestClock(base))
        let spend = await tracker.windowSpend(sidecar: "never-registered")
        XCTAssertEqual(spend, 0)
    }

    func testNegativeTokenCountsAreIgnoredRatherThanCreditingBudget() async {
        let tracker = makeTracker(clock: TestClock(base))

        await tracker.record(sidecar: sidecarName, inputTokens: 1_000, outputTokens: 0, at: base)
        await tracker.record(sidecar: sidecarName, inputTokens: -900, outputTokens: -50, at: base)

        let spend = await tracker.windowSpend(sidecar: sidecarName)
        XCTAssertEqual(spend, 1_000, "a bogus negative reading must not hand budget back")
    }

    // MARK: - Rolling window

    func testSpendAgesOutOfTheRollingWindow() async {
        let clock = TestClock(base)
        let tracker = makeTracker(clock: clock)

        await tracker.record(sidecar: sidecarName, inputTokens: 3_000_000, outputTokens: 0, at: base)
        var spend = await tracker.windowSpend(sidecar: sidecarName)
        XCTAssertEqual(spend, 3_000_000, "fresh spend is inside the window")

        // Six days on, still inside a 7-day window.
        clock.advance(hours: 24 * 6)
        spend = await tracker.windowSpend(sidecar: sidecarName)
        XCTAssertEqual(spend, 3_000_000, "spend from six days ago is still counted")

        // Past seven days, it should be gone.
        clock.advance(hours: 24 * 2)
        spend = await tracker.windowSpend(sidecar: sidecarName)
        XCTAssertEqual(spend, 0, "spend older than the window must age out, or a sidecar throttles forever")
    }

    func testWindowSlidesRatherThanResettingWholesale() async {
        let clock = TestClock(base)
        let tracker = makeTracker(clock: clock)

        await tracker.record(sidecar: sidecarName, inputTokens: 1_000_000, outputTokens: 0, at: base)
        clock.advance(hours: 24 * 4)
        let midpoint = clock.nowMs
        await tracker.record(sidecar: sidecarName, inputTokens: 500_000, outputTokens: 0, at: midpoint)

        // Now step past the first entry's expiry but not the second's.
        clock.advance(hours: 24 * 4)
        let spend = await tracker.windowSpend(sidecar: sidecarName)
        XCTAssertEqual(spend, 500_000, "only the aged-out portion should drop, not the whole ledger")
    }

    // MARK: - Percent and allowance

    func testDefaultCapIsFiveMillionTokens() {
        XCTAssertEqual(
            SidecarSpendTracker.Defaults.weeklyCapTokens, 5_000_000,
            "the documented default cap and the capPct x ceiling arithmetic must agree"
        )
    }

    func testSpendPercentIsShareOfAllowance() async {
        let tracker = makeTracker(clock: TestClock(base))
        await tracker.record(sidecar: sidecarName, inputTokens: allowance / 2, outputTokens: 0, at: base)

        let pct = await tracker.spendPercent(sidecar: sidecarName, capPct: 20)
        XCTAssertEqual(pct, 50)
    }

    func testSpendPercentIsNilWithoutACeilingRatherThanZero() async {
        let clock = TestClock(base)
        let tracker = makeTracker(clock: clock)
        await tracker.setAssumedWeeklyCeilingTokens(0)
        await tracker.record(sidecar: sidecarName, inputTokens: 1_000_000, outputTokens: 0, at: base)

        let pct = await tracker.spendPercent(sidecar: sidecarName, capPct: 20)
        XCTAssertNil(pct, "no ceiling means no honest percentage — nil, not a fabricated 0%")

        let spend = await tracker.windowSpend(sidecar: sidecarName)
        XCTAssertEqual(spend, 1_000_000, "the raw token count is still knowable without a ceiling")
    }

    func testOverspendReportsAboveOneHundredPercent() async {
        let tracker = makeTracker(clock: TestClock(base))
        await tracker.record(sidecar: sidecarName, inputTokens: allowance * 2, outputTokens: 0, at: base)

        let pct = await tracker.spendPercent(sidecar: sidecarName, capPct: 20)
        XCTAssertEqual(pct, 200, "an overspend should read honestly, not clamp to 100")
    }

    // MARK: - Throttle decisions

    func testThrottleThresholds() async {
        let tracker = makeTracker(clock: TestClock(base))

        // Half the allowance — nothing to do.
        await tracker.record(sidecar: sidecarName, inputTokens: allowance / 2, outputTokens: 0, at: base)
        var action = await tracker.shouldThrottle(sidecar: sidecarName, capPct: 20)
        XCTAssertEqual(action, ThrottleAction.none)

        // Push to 80% — drop a tier.
        await tracker.record(sidecar: sidecarName, inputTokens: (allowance * 30) / 100, outputTokens: 0, at: base)
        action = await tracker.shouldThrottle(sidecar: sidecarName, capPct: 20)
        XCTAssertEqual(action, .dropTier, "80% of the cap is the drop-a-tier line")

        // Push to 100% — off.
        await tracker.record(sidecar: sidecarName, inputTokens: (allowance * 20) / 100, outputTokens: 0, at: base)
        action = await tracker.shouldThrottle(sidecar: sidecarName, capPct: 20)
        XCTAssertEqual(action, .off, "at the cap the sidecar is switched off")
    }

    func testThrottleFailsOpenWhenCeilingIsUnknown() async {
        let tracker = makeTracker(clock: TestClock(base))
        await tracker.setAssumedWeeklyCeilingTokens(0)
        await tracker.record(sidecar: sidecarName, inputTokens: 999_000_000, outputTokens: 0, at: base)

        let action = await tracker.shouldThrottle(sidecar: sidecarName, capPct: 20)
        XCTAssertEqual(
            action, ThrottleAction.none,
            "an unknown ceiling is not grounds to switch a sidecar off"
        )
    }

    // MARK: - Callback behaviour

    func testCallbackFiresOnceOnEscalationNotOnEveryRecord() async {
        let log = ThrottleLog()
        let tracker = makeTracker(clock: TestClock(base)) { name, action in
            log.append(name, action)
        }

        // Cross 80% ...
        await tracker.record(sidecar: sidecarName, inputTokens: (allowance * 80) / 100, outputTokens: 0, at: base)
        XCTAssertEqual(log.actions, [.dropTier])

        // ... then keep recording small amounts inside the same band.
        for _ in 0..<5 {
            await tracker.record(sidecar: sidecarName, inputTokens: 1_000, outputTokens: 0, at: base)
        }
        XCTAssertEqual(
            log.actions, [.dropTier],
            "staying in the same band must not re-fire; Task D's handler would be called repeatedly"
        )
    }

    func testCallbackEscalatesFromDropTierToOff() async {
        let log = ThrottleLog()
        let tracker = makeTracker(clock: TestClock(base)) { name, action in
            log.append(name, action)
        }

        await tracker.record(sidecar: sidecarName, inputTokens: (allowance * 80) / 100, outputTokens: 0, at: base)
        await tracker.record(sidecar: sidecarName, inputTokens: (allowance * 20) / 100, outputTokens: 0, at: base)

        XCTAssertEqual(log.actions, [.dropTier, .off])
    }

    func testCallbackNeverDeEscalatesWhenSpendAgesOut() async {
        let clock = TestClock(base)
        let log = ThrottleLog()
        let tracker = makeTracker(clock: clock) { name, action in
            log.append(name, action)
        }

        await tracker.record(sidecar: sidecarName, inputTokens: allowance, outputTokens: 0, at: base)
        XCTAssertEqual(log.actions, [.off])

        // A week later the spend has aged out and headroom is back...
        clock.advance(hours: 24 * 8)
        await tracker.record(sidecar: sidecarName, inputTokens: 1_000, outputTokens: 0, at: clock.nowMs)

        XCTAssertEqual(
            log.actions, [.off],
            "regaining headroom must not restore a tier the user may have since tuned"
        )
    }

    func testLatchReArmsSoALaterClimbThrottlesAgain() async {
        let clock = TestClock(base)
        let log = ThrottleLog()
        let tracker = makeTracker(clock: clock) { name, action in
            log.append(name, action)
        }

        await tracker.record(sidecar: sidecarName, inputTokens: (allowance * 80) / 100, outputTokens: 0, at: base)
        XCTAssertEqual(log.actions, [.dropTier])

        // Age the spend out, then record a trickle to re-arm the latch.
        clock.advance(hours: 24 * 8)
        await tracker.record(sidecar: sidecarName, inputTokens: 1_000, outputTokens: 0, at: clock.nowMs)

        // Climb back over the line in the new window.
        await tracker.record(sidecar: sidecarName, inputTokens: (allowance * 80) / 100, outputTokens: 0, at: clock.nowMs)
        XCTAssertEqual(
            log.actions, [.dropTier, .dropTier],
            "a fresh window that blows the budget again must throttle again"
        )
    }

    func testNoCallbackForAnUnregisteredSidecar() async {
        let log = ThrottleLog()
        let tracker = makeTracker(clock: TestClock(base)) { name, action in
            log.append(name, action)
        }

        await tracker.record(sidecar: "never-registered", inputTokens: 999_000_000, outputTokens: 0, at: base)

        XCTAssertTrue(log.actions.isEmpty, "with no registration there is no cap to enforce")
        let spend = await tracker.windowSpend(sidecar: "never-registered")
        XCTAssertEqual(spend, 999_000_000, "the spend is still recorded in case registration lands later")
    }

    // MARK: - SidecarSpendReader

    func testSnapshotCarriesRawNumbersAndPercent() async {
        let tracker = makeTracker(clock: TestClock(base))
        await tracker.record(sidecar: sidecarName, inputTokens: allowance / 4, outputTokens: 0, at: base)

        let snapshot = await tracker.spendSnapshot(for: sidecarName)
        XCTAssertEqual(snapshot?.spentTokens, allowance / 4)
        XCTAssertEqual(snapshot?.allowanceTokens, allowance)
        XCTAssertEqual(snapshot?.percentUsed, 25)
    }

    func testSnapshotIsNilForAnUnregisteredSidecar() async {
        let tracker = makeTracker(clock: TestClock(base))
        let snapshot = await tracker.spendSnapshot(for: "never-registered")
        XCTAssertNil(snapshot, "no registration means no cap, so there is no bar to draw")
    }

    func testReaderProtocolIsUsableWithoutTheConcreteType() async {
        let tracker = makeTracker(clock: TestClock(base))
        await tracker.record(sidecar: sidecarName, inputTokens: allowance / 2, outputTokens: 0, at: base)

        // The point of the protocol: display code holds this and cannot record.
        let reader: SidecarSpendReader = tracker
        let snapshot = await reader.spendSnapshot(for: sidecarName)
        XCTAssertEqual(snapshot?.percentUsed, 50)
    }
}
