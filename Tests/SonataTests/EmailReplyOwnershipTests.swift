import XCTest
import GRDB
@testable import Sonata

/// The first-reply-to-an-unclaimed-thread ownership gap.
///
/// `email_reply` has always tried to record thread ownership on outbound, but it
/// resolved the thread id through `EmailThreadOwnership.threadId(forMessageId:)`,
/// which reads the `emails` table — i.e. only messages Sonata has already
/// ingested. On the FIRST reply to a thread with no prior Sonata-side messages
/// that lookup returns nil, the `let threadId` guard fails, and ownership is
/// silently not recorded.
///
/// That is the worst possible moment for it to fail. No owner recorded means the
/// next inbound message on the thread falls through to normal dispatch, a pool
/// worker claims it, and two versions of Sona answer the same conversation with
/// different context — the incident class Evan flagged three times in one day
/// while the AFK protocol was being built, and which recurred on 2026-08-02
/// (worker-6870623999, Scout thread 2e897108, `ownershipRecorded: false`).
///
/// The fix asks the PROVIDER for the thread id when our own store can't answer.
/// Every test here drives that through `EmailOutboundGateway`'s override seam,
/// so the whole path is exercised without a single network call.
final class EmailReplyOwnershipTests: XCTestCase {

    // MARK: - Helpers

    private func harness() throws -> MCPTestHarness {
        let h = try MCPTestHarness.make()
        h.actionRegistry.register(emailOutboundActions)
        return h
    }

    private func seedInbox(
        _ pool: DatabasePool,
        address: String = "sona@agentmail.to",
        provider: String = "agentmail"
    ) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO emailInboxes (address, role, enabled, autoReply, provider, createdAt, updatedAt)
                VALUES (?, 'assistant', 1, 1, ?, ?, ?)
            """, arguments: [address, provider, nowMs(), nowMs()])
        }
    }

    private func seedEmail(
        _ pool: DatabasePool, messageId: String, threadId: String
    ) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO emails (messageId, threadId, fromAddr, toAddr, subject, body, status, receivedAt)
                VALUES (?, ?, 'evan@example.com', 'sona@agentmail.to', 'status', 'body', 'unread', ?)
            """, arguments: [messageId, threadId, nowMs()])
        }
    }

    /// Counts how many times the provider was asked to resolve a thread id, so a
    /// test can assert the fallback did NOT fire on the common path.
    private actor ResolveCounter {
        private(set) var count = 0
        private(set) var lastMessageId: String?
        func note(_ messageId: String) { count += 1; lastMessageId = messageId }
    }

    private func parseJSON(_ raw: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(raw?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The decoded `EmailReplyResponse` payload of a `tools/call` reply.
    private func replyPayload(_ raw: String?) throws -> [String: Any] {
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "reply should succeed; got \(result)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func reply(
        _ h: MCPTestHarness,
        messageId: String,
        sessionKey: String = "session-abc",
        role: SessionRole = .interactive
    ) async throws -> [String: Any] {
        let raw = await h.handle(
            sessionKey: sessionKey, role: role,
            method: "tools/call", id: 1,
            params: ["name": "email_reply", "arguments": [
                "messageId": messageId, "text": "on it",
            ]])
        return try replyPayload(raw)
    }

    // MARK: - 1. Already-ingested thread: unchanged behavior, no provider call

    /// The pre-existing happy path still works — and, importantly, still costs
    /// nothing extra. The provider fallback is a fallback: once any message on
    /// the thread is in `emails`, the local read answers and no HTTP happens.
    func testReplyToIngestedMessageRecordsOwnershipWithoutAskingProvider() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool)
        try await seedEmail(h.dbPool, messageId: "MSG-1", threadId: "THREAD-1")

        let resolves = ResolveCounter()
        EmailOutboundGateway.shared.setOverrides(
            send: nil,
            reply: { _, _, _ in },
            resolveThreadId: { _, messageId in
                await resolves.note(messageId)
                return "THREAD-FROM-PROVIDER"
            })
        defer { EmailOutboundGateway.shared.setOverrides(send: nil, reply: nil) }

        let payload = try await reply(h, messageId: "MSG-1")

        XCTAssertEqual(payload["threadId"] as? String, "THREAD-1")
        XCTAssertEqual(payload["ownershipRecorded"] as? Bool, true)
        let owner = await EmailThreadOwnership.owner(threadId: "THREAD-1", dbPool: h.dbPool)
        XCTAssertEqual(owner, "session-abc")

        let calls = await resolves.count
        XCTAssertEqual(calls, 0, "local lookup hit — the provider must not be asked")
    }

    // MARK: - 2. THE FIX: never-ingested thread now records ownership

    /// The bug, and the regression guard for it. `MSG-NEW` is deliberately NOT
    /// seeded into `emails`, which is exactly the state of a thread whose first
    /// message the poller hasn't picked up yet. Before the fix this returned
    /// `ownershipRecorded: false` and left the thread unclaimed.
    func testReplyToUningestedMessageResolvesThreadIdFromProviderAndRecords() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool)

        let resolves = ResolveCounter()
        EmailOutboundGateway.shared.setOverrides(
            send: nil,
            reply: { _, _, _ in },
            resolveThreadId: { _, messageId in
                await resolves.note(messageId)
                return "THREAD-FROM-PROVIDER"
            })
        defer { EmailOutboundGateway.shared.setOverrides(send: nil, reply: nil) }

        let payload = try await reply(h, messageId: "MSG-NEW")

        XCTAssertEqual(payload["sent"] as? Bool, true)
        XCTAssertEqual(payload["threadId"] as? String, "THREAD-FROM-PROVIDER")
        XCTAssertEqual(payload["ownershipRecorded"] as? Bool, true)

        let owner = await EmailThreadOwnership.owner(
            threadId: "THREAD-FROM-PROVIDER", dbPool: h.dbPool)
        XCTAssertEqual(owner, "session-abc", "the thread must now be claimed by the replying session")

        let calls = await resolves.count
        let asked = await resolves.lastMessageId
        XCTAssertEqual(calls, 1, "local lookup missed — the provider must be asked exactly once")
        XCTAssertEqual(asked, "MSG-NEW")
    }

    // MARK: - 3 & 4. The guards that must NOT change

    /// Design, not regression: a worker replying is doing dispatched work, not
    /// holding a conversation, and must never become the thread's owner. The
    /// provider fallback must not become a back door around that — so this
    /// asserts the miss-path too, where the fix is active.
    func testWorkerReplyDoesNotRecordOwnershipEvenWhenThreadIdResolves() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool)

        EmailOutboundGateway.shared.setOverrides(
            send: nil,
            reply: { _, _, _ in },
            resolveThreadId: { _, _ in "THREAD-FROM-PROVIDER" })
        defer { EmailOutboundGateway.shared.setOverrides(send: nil, reply: nil) }

        let payload = try await reply(
            h, messageId: "MSG-NEW", sessionKey: "worker-1", role: .worker)

        // The thread id is still reported — it is useful information — but the
        // ownership row is not written.
        XCTAssertEqual(payload["threadId"] as? String, "THREAD-FROM-PROVIDER")
        XCTAssertEqual(payload["ownershipRecorded"] as? Bool, false)
        let owner = await EmailThreadOwnership.owner(
            threadId: "THREAD-FROM-PROVIDER", dbPool: h.dbPool)
        XCTAssertNil(owner, "a worker must not claim a thread")
    }

    /// Also design: no session key, nobody to record as owner.
    func testReplyWithoutSessionKeyDoesNotRecordOwnership() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool)

        EmailOutboundGateway.shared.setOverrides(
            send: nil,
            reply: { _, _, _ in },
            resolveThreadId: { _, _ in "THREAD-FROM-PROVIDER" })
        defer { EmailOutboundGateway.shared.setOverrides(send: nil, reply: nil) }

        let payload = try await reply(h, messageId: "MSG-NEW", sessionKey: "", role: .interactive)

        XCTAssertEqual(payload["ownershipRecorded"] as? Bool, false)
        let owner = await EmailThreadOwnership.owner(
            threadId: "THREAD-FROM-PROVIDER", dbPool: h.dbPool)
        XCTAssertNil(owner)
    }

    // MARK: - 5. A provider failure must not corrupt the reply's own result

    /// By the time the thread id is resolved the reply has ALREADY been sent, so
    /// a provider hiccup here must degrade to "ownership unrecorded" — the
    /// pre-fix behavior — and must never turn a delivered message into an error
    /// response. Reporting `sent: false` for mail that actually went out would
    /// be a worse bug than the one being fixed.
    func testProviderFailureDegradesToUnrecordedWithoutFailingTheReply() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool)

        struct Boom: Error {}
        EmailOutboundGateway.shared.setOverrides(
            send: nil,
            reply: { _, _, _ in },
            resolveThreadId: { _, _ in throw Boom() })
        defer { EmailOutboundGateway.shared.setOverrides(send: nil, reply: nil) }

        let payload = try await reply(h, messageId: "MSG-NEW")

        XCTAssertEqual(payload["sent"] as? Bool, true, "the mail was delivered; say so")
        XCTAssertNil(payload["threadId"] as? String)
        XCTAssertEqual(payload["ownershipRecorded"] as? Bool, false)
    }

    // MARK: - 6. The honest limit of the remedy

    /// `getMessage(inboxId:messageId:)` is AgentMail-specific — it is not on the
    /// `EmailProvider` protocol — so an IMAP/SMTP inbox has no equivalent and
    /// keeps exactly the behavior it had before this fix. This asserts the
    /// degradation is silent-and-nil rather than a crash or a stray network
    /// call, and it runs the LIVE resolve path (no override) precisely because
    /// the point is that the live path makes no HTTP request for IMAP.
    func testImapInboxResolvesToNilRatherThanAttemptingAgentMailFetch() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool, address: "evan@imap.example.com", provider: "imap")

        let inbox = InboxConfig(
            address: "evan@imap.example.com", role: .sona, provider: "imap")
        let resolved = try await EmailOutboundGateway.shared.resolveThreadId(
            inbox: inbox, messageId: "MSG-NEW")

        XCTAssertNil(resolved, "IMAP has no getMessage primitive — nil, matching pre-fix behavior")
    }
}
