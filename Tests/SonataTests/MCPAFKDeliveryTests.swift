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
