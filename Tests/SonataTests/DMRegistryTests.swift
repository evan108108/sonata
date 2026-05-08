import XCTest
@testable import Sonata

// Sonar DMs v0 — DMRegistry unit tests. Plan §8.1.
//
// All in-memory; no GRDB. Heartbeat checker is injected so tests can flip
// freshness deterministically without mocking workers / ExternalBridgeRegistry.

final class DMRegistryTests: XCTestCase {

    // MARK: register / lookup / unregister

    func testRegisterLookupUnregisterRoundtrip() {
        let reg = DMRegistry()
        reg.register(sessionId: "s1", sessionLabel: "alpha", role: "worker")
        XCTAssertTrue(reg.has("s1"))
        let entries = reg.listRegistrations()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sessionId, "s1")
        XCTAssertEqual(entries[0].sessionLabel, "alpha")
        XCTAssertEqual(entries[0].role, "worker")

        reg.unregister(sessionId: "s1")
        XCTAssertFalse(reg.has("s1"))
        XCTAssertEqual(reg.listRegistrations().count, 0)
    }

    func testIdempotentReregisterOverwrites() {
        let reg = DMRegistry()
        reg.register(sessionId: "s1", sessionLabel: "first", role: nil)
        reg.register(sessionId: "s1", sessionLabel: "second", role: "orchestrator")
        let entries = reg.listRegistrations()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sessionLabel, "second")
        XCTAssertEqual(entries[0].role, "orchestrator")
    }

    func testUnregisterAbsentIsNoop() {
        let reg = DMRegistry()
        reg.unregister(sessionId: "never-registered")
        XCTAssertFalse(reg.has("never-registered"))
    }

    // MARK: enqueue / claimReplies

    func testEnqueueAndDrain() {
        let reg = DMRegistry()
        reg.register(sessionId: "s1", sessionLabel: nil, role: nil)
        let env = makeEnvelope(messageId: "m1", target: "s1")
        XCTAssertTrue(reg.enqueue(env))

        let drained = reg.claimReplies(sessionId: "s1")
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].messageId, "m1")

        // Second drain returns empty (in-memory queue cleared).
        XCTAssertEqual(reg.claimReplies(sessionId: "s1").count, 0)
    }

    func testEnqueueWithoutRegistrationReturnsFalse() {
        let reg = DMRegistry()
        let env = makeEnvelope(messageId: "m1", target: "ghost")
        XCTAssertFalse(reg.enqueue(env))
        XCTAssertEqual(reg.claimReplies(sessionId: "ghost").count, 0)
    }

    // MARK: per-target cap

    func testPerTargetCapDropsOldest() {
        var dropMessages: [String] = []
        let reg = DMRegistry(warn: { msg in dropMessages.append(msg) })
        reg.register(sessionId: "s1", sessionLabel: nil, role: nil)

        let cap = DMLimits.perTargetCap
        // Push cap+5 envelopes; expect first 5 to be dropped.
        for i in 0..<(cap + 5) {
            let env = makeEnvelope(messageId: "m\(i)", target: "s1")
            _ = reg.enqueue(env)
        }
        let queue = reg._peekQueue(sessionId: "s1")
        XCTAssertEqual(queue.count, cap)
        // Oldest surviving messageId should be m5.
        XCTAssertEqual(queue.first?.messageId, "m5")
        // Newest should be m{cap+4}.
        XCTAssertEqual(queue.last?.messageId, "m\(cap + 4)")
        // Warn fired 5 times.
        XCTAssertEqual(dropMessages.count, 5)
        XCTAssertTrue(dropMessages.allSatisfy { $0.contains("dm_overflow") })
    }

    // MARK: seenMessageIds LRU

    func testDuplicateMessageIdDroppedAtRegistry() {
        let reg = DMRegistry()
        reg.register(sessionId: "s1", sessionLabel: nil, role: nil)
        let env = makeEnvelope(messageId: "m1", target: "s1")
        XCTAssertTrue(reg.enqueue(env))
        XCTAssertTrue(reg.enqueue(env))  // duplicate — returns true (registered) but doesn't queue
        let queue = reg._peekQueue(sessionId: "s1")
        XCTAssertEqual(queue.count, 1)
    }

    func testSeenLruEvictsOldest() {
        let reg = DMRegistry()
        reg.register(sessionId: "s1", sessionLabel: nil, role: nil)
        let cap = DMLimits.seenLruCap
        // Send cap+1 unique messages — first one should be evicted from the LRU.
        for i in 0..<(cap + 1) {
            _ = reg.enqueue(makeEnvelope(messageId: "m\(i)", target: "s1"))
        }
        // Replay m0; should NOT be detected as duplicate since LRU evicted it.
        // (But since it's already in the queue from the first send, we can't
        // observe re-enqueue via the queue. Instead inspect the LRU ring.)
        let ring = reg._peekSeenRing(sessionId: "s1")
        XCTAssertNotNil(ring)
        XCTAssertFalse(ring!.contains("m0"))
        XCTAssertTrue(ring!.contains("m\(cap)"))
    }

    // MARK: pruneStale

    func testPruneStaleRemovesRegistrationsWithoutHeartbeat() async {
        let reg = DMRegistry()
        // checker says only "s1" is fresh.
        let checker = DMHeartbeatChecker(isFresh: { sid in sid == "s1" })
        reg.setHeartbeatChecker(checker)

        reg.register(sessionId: "s1", sessionLabel: nil, role: nil)
        reg.register(sessionId: "s2", sessionLabel: nil, role: nil)

        await reg.runPruneOnce()

        XCTAssertTrue(reg.has("s1"))
        XCTAssertFalse(reg.has("s2"))
    }

    func testPruneStaleClearsOrphanQueues() async {
        let reg = DMRegistry()
        reg.setHeartbeatChecker(DMHeartbeatChecker(isFresh: { _ in false }))

        // Force a queue without a registration via enqueue → fail → manually
        // simulate by registering, queueing, then unregistering. Belt-and-braces:
        // confirm prune cleans whatever is left.
        reg.register(sessionId: "s1", sessionLabel: nil, role: nil)
        _ = reg.enqueue(makeEnvelope(messageId: "m1", target: "s1"))
        XCTAssertEqual(reg._peekQueue(sessionId: "s1").count, 1)

        await reg.runPruneOnce()

        XCTAssertFalse(reg.has("s1"))
        XCTAssertEqual(reg._peekQueue(sessionId: "s1").count, 0)
    }

    // MARK: helpers

    private func makeEnvelope(messageId: String, target: String) -> DMEnvelope {
        DMEnvelope(
            messageId: messageId,
            fromSessionId: "sender",
            fromPubkey: nil,
            fromPeerId: nil,
            targetSessionId: target,
            body: "hi from \(messageId)",
            context: nil,
            sentAtMs: 1000,
            receivedAtMs: 1001,
            metaJson: nil
        )
    }
}
