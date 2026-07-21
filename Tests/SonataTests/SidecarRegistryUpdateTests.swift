import XCTest
@testable import Sonata

// Tests for `SidecarRegistry.update(_:)` and the budget-tier ladder it is
// driven by.
//
// `update` exists for exactly one caller — the spend tracker's throttle
// handler, which has to write a changed `Sidecar` back under a name that is by
// definition already registered. The cases worth pinning down are the ones
// where a naive implementation quietly corrupts routing: an update that leaves
// the event-type index pointing at the old config, or one that rejects a
// sidecar for "colliding" with its own event types.
//
// The registry is a process-wide singleton, so every test resets it on both
// sides — a leaked registration would surface as an unrelated test failing
// later with a `duplicateName`.
final class SidecarRegistryUpdateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SidecarRegistry.shared.reset()
    }

    override func tearDown() {
        SidecarRegistry.shared.reset()
        super.tearDown()
    }

    private func makeSidecar(
        name: String = "memory",
        eventTypes: [String] = ["memory_request"],
        tier: SidecarBudgetTier = .standard,
        capPct: Int = 20
    ) -> Sidecar {
        Sidecar(
            name: name,
            skillPath: "/nonexistent/SKILL.md",
            eventTypes: eventTypes,
            budgetTier: tier,
            subscriptionCapPct: capPct
        )
    }

    // MARK: - The throttle handler's actual use

    /// The case `update` was added for: re-registering under an existing name
    /// throws, so a tier drop needs a way in that isn't `register`.
    func testRegisterRejectsWhatUpdateAccepts() throws {
        let sidecar = makeSidecar(tier: .high)
        try SidecarRegistry.shared.register(sidecar)

        let dropped = makeSidecar(tier: .standard)
        XCTAssertThrowsError(try SidecarRegistry.shared.register(dropped)) { error in
            guard case SidecarRegistry.RegistrationError.duplicateName = error else {
                return XCTFail("expected duplicateName, got \(error)")
            }
        }

        try SidecarRegistry.shared.update(dropped)
        XCTAssertEqual(SidecarRegistry.shared.lookup(byName: "memory")?.budgetTier, .standard)
    }

    func testUpdateReplacesConfigInPlace() throws {
        try SidecarRegistry.shared.register(makeSidecar(tier: .high, capPct: 20))
        try SidecarRegistry.shared.update(makeSidecar(tier: .low, capPct: 5))

        let stored = SidecarRegistry.shared.lookup(byName: "memory")
        XCTAssertEqual(stored?.budgetTier, .low)
        XCTAssertEqual(stored?.subscriptionCapPct, 5)
    }

    func testUpdateThrowsOnUnknownName() {
        XCTAssertThrowsError(try SidecarRegistry.shared.update(makeSidecar())) { error in
            guard case SidecarRegistry.RegistrationError.unknownName = error else {
                return XCTFail("expected unknownName, got \(error)")
            }
        }
    }

    // MARK: - Routing consistency

    /// Keeping the same event types must not read as a collision with itself.
    /// This is the bug a self-inclusive ownership check would introduce, and it
    /// would make every single throttle-driven tier drop fail.
    func testUpdateDoesNotCollideWithItsOwnEventTypes() throws {
        try SidecarRegistry.shared.register(makeSidecar())
        XCTAssertNoThrow(try SidecarRegistry.shared.update(makeSidecar(tier: .low)))
        XCTAssertEqual(SidecarRegistry.shared.lookup(byEventType: "memory_request")?.name, "memory")
    }

    /// An update that changes the event-type set has to rebuild the index, or
    /// routing keeps sending the dropped type at a sidecar that disowned it.
    func testUpdateRebuildsTheEventTypeIndex() throws {
        try SidecarRegistry.shared.register(makeSidecar(eventTypes: ["memory_request"]))
        try SidecarRegistry.shared.update(makeSidecar(eventTypes: ["memory_lookup"]))

        XCTAssertNil(SidecarRegistry.shared.lookup(byEventType: "memory_request"))
        XCTAssertEqual(SidecarRegistry.shared.lookup(byEventType: "memory_lookup")?.name, "memory")
    }

    /// Ownership is still one-event-type-one-sidecar across *different*
    /// sidecars, and a rejected update must leave the registry untouched.
    func testUpdateRejectsATypeOwnedByAnotherSidecarAndRollsBack() throws {
        try SidecarRegistry.shared.register(makeSidecar(name: "memory", eventTypes: ["memory_request"]))
        try SidecarRegistry.shared.register(makeSidecar(name: "research", eventTypes: ["research_request"]))

        let greedy = makeSidecar(name: "research", eventTypes: ["research_request", "memory_request"])
        XCTAssertThrowsError(try SidecarRegistry.shared.update(greedy)) { error in
            guard case SidecarRegistry.RegistrationError.eventTypeAlreadyOwned = error else {
                return XCTFail("expected eventTypeAlreadyOwned, got \(error)")
            }
        }

        XCTAssertEqual(SidecarRegistry.shared.lookup(byEventType: "memory_request")?.name, "memory")
        XCTAssertEqual(SidecarRegistry.shared.lookup(byEventType: "research_request")?.name, "research")
    }

    /// The live session key belongs to `SidecarLifecycle`, not to config. An
    /// update that reset it would silently undo a mid-rotation withdrawal and
    /// route events at a session being torn down.
    func testUpdatePreservesTheLiveSessionKey() throws {
        try SidecarRegistry.shared.register(makeSidecar())
        SidecarRegistry.shared.setSessionKey("sidecar-memory", for: "memory")

        try SidecarRegistry.shared.update(makeSidecar(tier: .low))

        XCTAssertEqual(SidecarRegistry.shared.sessionKey(for: "memory"), "sidecar-memory")
        XCTAssertEqual(SidecarRegistry.shared.assignee(forEventType: "memory_request"), "sidecar-memory")
    }

    // MARK: - The routing seam's contract

    /// What the enqueue seam relies on: no owner, or an owner with no live
    /// session, both mean "route normally".
    func testAssigneeIsNilWithoutAnOwnerOrASession() throws {
        XCTAssertNil(SidecarRegistry.shared.assignee(forEventType: "memory_request"))

        try SidecarRegistry.shared.register(makeSidecar())
        XCTAssertNil(SidecarRegistry.shared.assignee(forEventType: "memory_request"))

        SidecarRegistry.shared.setSessionKey("sidecar-memory", for: "memory")
        XCTAssertEqual(SidecarRegistry.shared.assignee(forEventType: "memory_request"), "sidecar-memory")

        // Mid-rotation: key withdrawn, events fall through again.
        SidecarRegistry.shared.setSessionKey(nil, for: "memory")
        XCTAssertNil(SidecarRegistry.shared.assignee(forEventType: "memory_request"))
    }

    // MARK: - Tier ladder

    func testTierLadderStepsDownOneAtATimeAndBottomsOut() {
        XCTAssertEqual(SidecarBudgetTier.high.nextLower, .standard)
        XCTAssertEqual(SidecarBudgetTier.standard.nextLower, .low)
        XCTAssertEqual(SidecarBudgetTier.low.nextLower, .off)
        XCTAssertNil(SidecarBudgetTier.off.nextLower)
    }

    /// Walking the ladder from the top must terminate — the throttle handler
    /// guards on `nextLower` being nil to know when to stop.
    func testRepeatedDropsTerminateAtOff() {
        var tier = SidecarBudgetTier.high
        var steps = 0
        while let lower = tier.nextLower {
            tier = lower
            steps += 1
            XCTAssertLessThanOrEqual(steps, SidecarBudgetTier.allCases.count)
        }
        XCTAssertEqual(tier, .off)
        XCTAssertEqual(steps, 3)
    }
}
