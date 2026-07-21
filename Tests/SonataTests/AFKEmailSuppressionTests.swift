import XCTest
import GRDB
@testable import Sonata

/// Root-fix verification for the recurring "two Sonas on one thread" class.
///
/// The failure: while Global AFK is on, an interactive session holds an email
/// conversation with the user. Every inbound reply on that thread was dispatched
/// as a first-class `email` workerEvent, whose payload instructs the claiming
/// worker to read, reply, mark replied and complete. The worker obeyed — and
/// appeared on the thread as a second voice. Three recurrences in one day, each
/// re-derived by a fresh worker, because the only guard was prose in a SKILL.
///
/// The fix has two halves, and both are exercised here:
///   1. Ownership becomes knowable at all. Sonata never observed outbound mail
///      (sessions sent via the AgentMail MCP server, which never touches this
///      process), so "who owns this thread" had no answer. `email_send` /
///      `email_reply` are the seam that supplies one.
///   2. Dispatch is suppressed when a live owner exists — the event carrying the
///      wrong instructions is never created.
final class AFKEmailSuppressionTests: XCTestCase {

    // MARK: - Helpers

    private func harness() throws -> MCPTestHarness {
        let h = try MCPTestHarness.make()
        h.actionRegistry.register(emailOutboundActions)
        return h
    }

    private func setGlobalAFK(_ enabled: Bool, _ pool: DatabasePool) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE globalAFK SET enabled = ?, enabledAt = ? WHERE id = 1",
                arguments: [enabled ? 1 : 0, nowMs()])
        }
    }

    private func seedInbox(_ pool: DatabasePool, address: String = "sona@agentmail.to") async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO emailInboxes (address, role, enabled, autoReply, provider, createdAt, updatedAt)
                VALUES (?, 'assistant', 1, 1, 'agentmail', ?, ?)
            """, arguments: [address, nowMs(), nowMs()])
        }
    }

    private func seedEmail(
        _ pool: DatabasePool, messageId: String, threadId: String, subject: String
    ) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO emails (messageId, threadId, fromAddr, toAddr, subject, body, status, receivedAt)
                VALUES (?, ?, 'evan@example.com', 'sona@agentmail.to', ?, 'body', 'unread', ?)
            """, arguments: [messageId, threadId, subject, nowMs()])
        }
    }

    private func record(_ email: EmailRecord? = nil, threadId: String, messageId: String) -> EmailRecord {
        EmailRecord(
            messageId: messageId,
            threadId: threadId,
            from: "evan@example.com",
            subject: "Re: status",
            body: "any update?",
            timestamp: "2026-07-21T23:00:00Z",
            inboxAddress: "sona@agentmail.to"
        )
    }

    /// An EmailHandler whose liveness + push are driven by the test rather than
    /// a real MCP connection. `pushed` collects (sessionKey, messageId) pairs.
    private func handler(
        _ pool: DatabasePool,
        liveSessions: Set<String>,
        pushSucceeds: Bool = true,
        pushed: PushRecorder
    ) -> EmailHandler {
        EmailHandler(
            dbPool: pool,
            isSessionLive: { key in liveSessions.contains(key) },
            pushToSession: { key, email in
                if pushSucceeds { await pushed.add(key: key, messageId: email.messageId) }
                return pushSucceeds
            }
        )
    }

    actor PushRecorder {
        private(set) var entries: [(key: String, messageId: String)] = []
        func add(key: String, messageId: String) { entries.append((key, messageId)) }
        var count: Int { entries.count }
    }

    // MARK: - 1. Outbound seam stamps the tag and records ownership

    /// AFK on + interactive caller → Sonata adds the routing tag the session
    /// never had to type. This is the half that stops the tag from being missed.
    func testSendUnderAFKAutoStampsSubjectForInteractiveSession() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool)
        try await setGlobalAFK(true, h.dbPool)

        let sent = SentRecorder()
        EmailOutboundGateway.shared.setOverrides(
            send: { _, _, subject, _ in await sent.record(subject) }, reply: nil)
        defer { EmailOutboundGateway.shared.setOverrides(send: nil, reply: nil) }

        let raw = await h.handle(
            sessionKey: "session-abc", role: .interactive,
            method: "tools/call", id: 1,
            params: ["name": "email_send", "arguments": [
                "to": "evan@example.com", "subject": "PR2 shipped", "text": "body",
            ]])

        XCTAssertNotNil(raw)
        let subject = await sent.subjects.first
        XCTAssertEqual(subject, "[AFK-#session-abc] PR2 shipped")
    }

    /// Idempotence: a subject that already carries a tag is left alone. Reply
    /// chains re-stamp constantly; double-stamping would corrupt the routing key.
    func testStampIsIdempotentAndPreservesAnExistingTag() {
        XCTAssertEqual(
            AFKSubjectTag.stamp(subject: "[AFK-#session-abc] PR2 shipped", sessionKey: "session-abc"),
            "[AFK-#session-abc] PR2 shipped")
        // An existing tag naming ANOTHER session also wins — a thread that
        // already advertises a routing key keeps it.
        XCTAssertEqual(
            AFKSubjectTag.stamp(subject: "[AFK-#session-other] hi", sessionKey: "session-abc"),
            "[AFK-#session-other] hi")
    }

    /// AFK off → no stamping. The normal inbox flow must be untouched.
    func testSendWithAFKOffDoesNotStamp() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool)
        try await setGlobalAFK(false, h.dbPool)

        let sent = SentRecorder()
        EmailOutboundGateway.shared.setOverrides(
            send: { _, _, subject, _ in await sent.record(subject) }, reply: nil)
        defer { EmailOutboundGateway.shared.setOverrides(send: nil, reply: nil) }

        _ = await h.handle(
            sessionKey: "session-abc", role: .interactive,
            method: "tools/call", id: 1,
            params: ["name": "email_send", "arguments": [
                "to": "evan@example.com", "subject": "PR2 shipped", "text": "body",
            ]])

        let subject = await sent.subjects.first
        XCTAssertEqual(subject, "PR2 shipped")
    }

    /// A worker sending under AFK is NOT tagged. Workers have no afk_reply
    /// surface, so routing replies at one would push into a session that can't
    /// consume them.
    func testWorkerSendIsNotStampedEvenUnderAFK() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool)
        try await setGlobalAFK(true, h.dbPool)

        let sent = SentRecorder()
        EmailOutboundGateway.shared.setOverrides(
            send: { _, _, subject, _ in await sent.record(subject) }, reply: nil)
        defer { EmailOutboundGateway.shared.setOverrides(send: nil, reply: nil) }

        _ = await h.handle(
            sessionKey: "worker-1", role: .worker,
            method: "tools/call", id: 1,
            params: ["name": "email_send", "arguments": [
                "to": "evan@example.com", "subject": "dispatched reply", "text": "body",
            ]])

        let subject = await sent.subjects.first
        XCTAssertEqual(subject, "dispatched reply")
    }

    /// Replying through Sonata claims the thread. This is the durable half —
    /// it survives a subject line the user's mail client mangles.
    func testReplyRecordsThreadOwnershipForInteractiveSession() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool)
        try await seedEmail(h.dbPool, messageId: "MSG-1", threadId: "THREAD-1", subject: "status")

        EmailOutboundGateway.shared.setOverrides(send: nil, reply: { _, _, _ in })
        defer { EmailOutboundGateway.shared.setOverrides(send: nil, reply: nil) }

        _ = await h.handle(
            sessionKey: "session-abc", role: .interactive,
            method: "tools/call", id: 1,
            params: ["name": "email_reply", "arguments": [
                "messageId": "MSG-1", "text": "on it",
            ]])

        let owner = await EmailThreadOwnership.owner(threadId: "THREAD-1", dbPool: h.dbPool)
        XCTAssertEqual(owner, "session-abc")
    }

    /// A worker replying is doing dispatched work, not holding a conversation.
    /// If workers could claim ownership, the suppression would later route the
    /// user's mail at a worker that has long since exited.
    func testWorkerReplyDoesNotClaimOwnership() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await seedInbox(h.dbPool)
        try await seedEmail(h.dbPool, messageId: "MSG-1", threadId: "THREAD-1", subject: "status")

        EmailOutboundGateway.shared.setOverrides(send: nil, reply: { _, _, _ in })
        defer { EmailOutboundGateway.shared.setOverrides(send: nil, reply: nil) }

        _ = await h.handle(
            sessionKey: "worker-1", role: .worker,
            method: "tools/call", id: 1,
            params: ["name": "email_reply", "arguments": [
                "messageId": "MSG-1", "text": "handled",
            ]])

        let owner = await EmailThreadOwnership.owner(threadId: "THREAD-1", dbPool: h.dbPool)
        XCTAssertNil(owner)
    }

    /// Most recent sender wins, and firstSentAt survives the re-claim.
    func testOwnershipUpsertMostRecentSenderWins() async throws {
        let h = try harness()
        defer { h.teardown() }

        await EmailThreadOwnership.record(threadId: "T", sessionKey: "session-a", dbPool: h.dbPool)
        let firstAt: Int64? = try await h.dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT firstSentAt FROM emailThreadOwners WHERE threadId = 'T'")
        }
        await EmailThreadOwnership.record(threadId: "T", sessionKey: "session-b", dbPool: h.dbPool)

        let owner = await EmailThreadOwnership.owner(threadId: "T", dbPool: h.dbPool)
        XCTAssertEqual(owner, "session-b")

        let stillFirstAt: Int64? = try await h.dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT firstSentAt FROM emailThreadOwners WHERE threadId = 'T'")
        }
        XCTAssertEqual(stillFirstAt, firstAt, "re-claiming a thread must not rewrite when it started")

        let rowCount: Int? = try await h.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emailThreadOwners WHERE threadId = 'T'")
        }
        XCTAssertEqual(rowCount, 1, "threadId is the PK — a re-claim upserts, it doesn't accumulate rows")
    }

    // MARK: - 2. Suppression at dispatch

    /// THE FIX. AFK on + owner live → the email is pushed to the owning session
    /// and removed from the batch, so no `email` workerEvent is ever created and
    /// no worker can be handed instructions to reply.
    func testOwnedThreadUnderAFKIsRoutedToOwnerAndNotDispatched() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await setGlobalAFK(true, h.dbPool)
        await EmailThreadOwnership.record(
            threadId: "THREAD-1", sessionKey: "session-abc", dbPool: h.dbPool)

        let pushed = PushRecorder()
        let handler = handler(h.dbPool, liveSessions: ["session-abc"], pushed: pushed)

        let leftover = await handler.routeOwnedThreadEmails(
            [record(threadId: "THREAD-1", messageId: "MSG-9")])

        XCTAssertTrue(leftover.isEmpty, "an owned thread's mail must not reach worker dispatch")
        let entries = await pushed.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.key, "session-abc")
        XCTAssertEqual(entries.first?.messageId, "MSG-9")
    }

    /// The backward-safety guarantee. AFK off → identical behavior to before
    /// this change, even for a thread that has a recorded owner.
    func testAFKOffFallsThroughToWorkerDispatch() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await setGlobalAFK(false, h.dbPool)
        await EmailThreadOwnership.record(
            threadId: "THREAD-1", sessionKey: "session-abc", dbPool: h.dbPool)

        let pushed = PushRecorder()
        let handler = handler(h.dbPool, liveSessions: ["session-abc"], pushed: pushed)

        let leftover = await handler.routeOwnedThreadEmails(
            [record(threadId: "THREAD-1", messageId: "MSG-9")])

        XCTAssertEqual(leftover.count, 1, "AFK off must not suppress anything")
        let count = await pushed.count
        XCTAssertEqual(count, 0)
    }

    /// A dead owner must fall through. Suppressing here would strand the user's
    /// mail in a session that closed — worse than a worker answering it.
    func testDeadOwnerFallsThroughToWorkerDispatch() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await setGlobalAFK(true, h.dbPool)
        await EmailThreadOwnership.record(
            threadId: "THREAD-1", sessionKey: "session-gone", dbPool: h.dbPool)

        let pushed = PushRecorder()
        let handler = handler(h.dbPool, liveSessions: [], pushed: pushed)

        let leftover = await handler.routeOwnedThreadEmails(
            [record(threadId: "THREAD-1", messageId: "MSG-9")])

        XCTAssertEqual(leftover.count, 1)
        let count = await pushed.count
        XCTAssertEqual(count, 0)
    }

    /// An unowned thread is untouched — the ordinary inbox case.
    func testUnownedThreadFallsThroughEvenUnderAFK() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await setGlobalAFK(true, h.dbPool)

        let pushed = PushRecorder()
        let handler = handler(h.dbPool, liveSessions: ["session-abc"], pushed: pushed)

        let leftover = await handler.routeOwnedThreadEmails(
            [record(threadId: "THREAD-UNKNOWN", messageId: "MSG-9")])

        XCTAssertEqual(leftover.count, 1)
        let count = await pushed.count
        XCTAssertEqual(count, 0)
    }

    /// A failed push falls through rather than swallowing the email. Silent
    /// suppression is the one outcome worse than the original bug.
    func testFailedPushFallsThroughToWorkerDispatch() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await setGlobalAFK(true, h.dbPool)
        await EmailThreadOwnership.record(
            threadId: "THREAD-1", sessionKey: "session-abc", dbPool: h.dbPool)

        let pushed = PushRecorder()
        let handler = handler(
            h.dbPool, liveSessions: ["session-abc"], pushSucceeds: false, pushed: pushed)

        let leftover = await handler.routeOwnedThreadEmails(
            [record(threadId: "THREAD-1", messageId: "MSG-9")])

        XCTAssertEqual(leftover.count, 1, "a push that didn't land must not eat the email")
    }

    /// Mixed batch: only the owned thread is pulled out; everything else still
    /// reaches normal dispatch.
    func testOnlyOwnedThreadIsPulledFromAMixedBatch() async throws {
        let h = try harness()
        defer { h.teardown() }
        try await setGlobalAFK(true, h.dbPool)
        await EmailThreadOwnership.record(
            threadId: "OWNED", sessionKey: "session-abc", dbPool: h.dbPool)

        let pushed = PushRecorder()
        let handler = handler(h.dbPool, liveSessions: ["session-abc"], pushed: pushed)

        let leftover = await handler.routeOwnedThreadEmails([
            record(threadId: "OWNED", messageId: "MSG-OWNED"),
            record(threadId: "OTHER", messageId: "MSG-OTHER"),
        ])

        XCTAssertEqual(leftover.map(\.messageId), ["MSG-OTHER"])
        let entries = await pushed.entries
        XCTAssertEqual(entries.map(\.messageId), ["MSG-OWNED"])
    }

    // MARK: - Recorders

    actor SentRecorder {
        private(set) var subjects: [String] = []
        func record(_ subject: String) { subjects.append(subject) }
    }
}
