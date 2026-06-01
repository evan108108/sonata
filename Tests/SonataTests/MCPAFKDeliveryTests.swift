import XCTest
@testable import Sonata

// Plan §9 test 5 — AFK delivery hook round-trip.
// Plan §12 G3 — verify AFKReply field names match what
// MCPNotificationDispatcher.pushAFKReply references. The test asserts each
// meta key by name; if a field gets renamed on either side the assertion
// fails. (The plan also called this gate "DMEnvelope alignment"; that path
// is exercised by the DM round-trip portion of MCPToolCallTests via
// sonar_dm_send → deliverDM, plus DMActionsTests on the persistence side.)

final class MCPAFKDeliveryTests: XCTestCase {

    func testAFKEnqueueReplyDeliversChannelFrameToAttachedSession() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        // Bind our test dispatcher to our registry. This installs a delivery
        // hook on AFKRegistry.shared that calls our dispatcher's
        // pushAFKReply (which in turn calls our registry's pushNotification).
        // Cleanup at end overwrites the hook with a no-op so unrelated
        // tests aren't affected.
        await h.dispatcher.bind(registry: h.mcpRegistry)
        addTeardownBlock {
            AFKRegistry.shared.setDeliveryHook { _, _ in }
            AFKRegistry.shared.unregister(token: "tok-afk-test")
        }

        let sessionKey = "afk-target"
        let (_, state) = await h.registerSession(sessionKey: sessionKey, role: .worker)
        let writer = MCPSSEWriter()
        await state.attachSSE(writer)

        AFKRegistry.shared.register(token: "tok-afk-test", sessionId: sessionKey)

        let reply = AFKReply(
            token: "tok-afk-test",
            replyText: "user said go ahead",
            fromAddr: "evan@example.com",
            subject: "[AFK:tok-afk-test] should I deploy?",
            messageId: "<msg-afk-1@example>",
            receivedAt: nowMs()
        )
        let delivered = AFKRegistry.shared.enqueueReply(reply)
        XCTAssertTrue(delivered, "enqueueReply should report true when the token is registered")

        let frames = await MCPSSEFrameCollector.collect(
            from: writer, timeout: 2.0,
            until: { $0.contains("tok-afk-test") }
        )
        let afkFrame = try XCTUnwrap(
            frames.first(where: { $0.contains("tok-afk-test") }),
            "expected an AFK reply frame in SSE stream; got \(frames)"
        )

        let data = try XCTUnwrap(afkFrame.data(using: .utf8))
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["method"] as? String, "notifications/claude/channel")

        let params = try XCTUnwrap(envelope["params"] as? [String: Any])
        let content = try XCTUnwrap(params["content"] as? String)
        XCTAssertTrue(content.contains("user said go ahead"),
            "channel content must include the reply body verbatim")
        XCTAssertTrue(content.contains("tok-afk-test"),
            "channel content header must include the token for human verification")

        // G3 alignment — every key the worker prompt references must be
        // present in the meta blob with the documented name.
        let meta = try XCTUnwrap(params["meta"] as? [String: Any])
        XCTAssertEqual(meta["event_type"] as? String, "afk_reply")
        XCTAssertEqual(meta["afk_token"] as? String, "tok-afk-test")
        XCTAssertEqual(meta["message_id"] as? String, "<msg-afk-1@example>")
        XCTAssertEqual(meta["from_addr"] as? String, "evan@example.com")
        XCTAssertEqual(meta["subject"] as? String, "[AFK:tok-afk-test] should I deploy?")
    }

    // FIX #2 (outbox / at-least-once) — a confirmed push acks the reply out of
    // the durable outbox, so a subsequent poll has nothing left to drain.
    func testAFKReplyIsAckedOutOfOutboxAfterSuccessfulPush() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        await h.dispatcher.bind(registry: h.mcpRegistry)
        addTeardownBlock {
            AFKRegistry.shared.setDeliveryHook { _, _ in }
            AFKRegistry.shared.unregister(token: "tok-afk-ack")
        }

        let sessionKey = "afk-ack-target"
        let (_, state) = await h.registerSession(sessionKey: sessionKey, role: .worker)
        let writer = MCPSSEWriter()
        await state.attachSSE(writer)

        AFKRegistry.shared.register(token: "tok-afk-ack", sessionId: sessionKey)

        let reply = AFKReply(
            token: "tok-afk-ack",
            replyText: "go ahead",
            fromAddr: "evan@example.com",
            subject: "[AFK:tok-afk-ack] ok?",
            messageId: "<msg-afk-ack@example>",
            receivedAt: nowMs()
        )
        XCTAssertTrue(AFKRegistry.shared.enqueueReply(reply))

        // Wait for the push to actually land on the SSE stream.
        let frames = await MCPSSEFrameCollector.collect(
            from: writer, timeout: 2.0,
            until: { $0.contains("tok-afk-ack") }
        )
        XCTAssertTrue(frames.contains(where: { $0.contains("tok-afk-ack") }),
            "expected the reply to be pushed over SSE")

        // The hook acks asynchronously right after pushChannel returns true.
        // Poll the outbox until it's empty (ack landed), bounded so a
        // regression — reply left in the outbox — fails instead of hanging.
        var drained: [AFKReply] = [reply]
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            drained = AFKRegistry.shared.claimReplies(sessionId: sessionKey)
            if drained.isEmpty { break }
        }
        XCTAssertTrue(drained.isEmpty,
            "a delivered reply must be acked out of the outbox, not left for re-delivery")
    }

    // FIX #2 — when the push fails (no live SSE writer), the reply must stay in
    // the outbox so a later reconnect/poll can drain it, instead of being lost
    // AND reported delivered (the original bug).
    func testAFKReplySurvivesInOutboxWhenPushFails() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        await h.dispatcher.bind(registry: h.mcpRegistry)
        addTeardownBlock {
            AFKRegistry.shared.setDeliveryHook { _, _ in }
            AFKRegistry.shared.unregister(token: "tok-afk-blind")
        }

        // Register the token to a session that has NO SSE writer attached, so
        // pushNotification returns false (alive-but-blind).
        let sessionKey = "afk-blind-target"
        AFKRegistry.shared.register(token: "tok-afk-blind", sessionId: sessionKey)

        let reply = AFKReply(
            token: "tok-afk-blind",
            replyText: "still want this delivered",
            fromAddr: "evan@example.com",
            subject: "[AFK:tok-afk-blind] reachable?",
            messageId: "<msg-afk-blind@example>",
            receivedAt: nowMs()
        )
        XCTAssertTrue(AFKRegistry.shared.enqueueReply(reply),
            "enqueueReply still reports true — the token is registered")

        // Give the async hook time to run and (correctly) NOT ack on failure.
        try await Task.sleep(nanoseconds: 300_000_000)

        let drained = AFKRegistry.shared.claimReplies(sessionId: sessionKey)
        XCTAssertEqual(drained.count, 1,
            "a reply whose push failed must remain durable in the outbox")
        XCTAssertEqual(drained.first?.messageId, "<msg-afk-blind@example>")
    }

    func testAFKEnqueueReplyReportsFalseWhenTokenUnknown() async {
        // No bind here — just exercising the registry's contract that an
        // unknown token returns false rather than misrouting.
        let reply = AFKReply(
            token: "definitely-not-registered",
            replyText: "lost reply",
            fromAddr: "x@y",
            subject: "x",
            messageId: "m",
            receivedAt: nowMs()
        )
        let delivered = AFKRegistry.shared.enqueueReply(reply)
        XCTAssertFalse(delivered)
    }
}
