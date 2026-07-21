import Foundation
import GRDB

// Sonata's outbound email seam.
//
// WHY THIS FILE EXISTS. Until now Sonata could send mail only from its own
// internal paths (EmailHandler's failure/approval notices, HealthMonitor). Every
// session-authored email went out through the AgentMail MCP server, a separate
// process Sonata never sees. Combined with an `emails` table that only ever
// receives inbound rows, that left Sonata structurally unable to answer "which
// session is holding this thread?" — and an inbound reply on a thread a
// coordinator owned was dispatched to whichever pool worker claimed it first.
//
// Routing already had a key for this — the `[AFK-#<sessionId>]` subject tag
// EmailHandler matches — but it was free text the composing session had to type
// correctly on every message, with no enforcement and no fallback. It was missed
// three times in one day.
//
// Sending through here fixes both halves at once: the tag is stamped
// automatically (§ AFKSubjectTag) and ownership is recorded from the caller's
// own session identity (§ EmailThreadOwnership). Neither depends on anyone
// remembering to type anything.

// MARK: - AFK subject tag

enum AFKSubjectTag {

    /// Prepend `[AFK-#<sessionKey>]` unless the subject already carries a tag.
    ///
    /// Idempotent by design: re-stamping a reply chain's subject must not
    /// produce `[AFK-#a][AFK-#a] …`. Any existing tag wins, even one naming a
    /// different session — a thread that already advertises a routing key keeps
    /// it, so a session picking up someone else's thread can't silently steal
    /// the routing out from under it.
    static func stamp(subject: String, sessionKey: String) -> String {
        if EmailHandler.extractAFKSessionId(from: subject) != nil { return subject }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "[AFK-#\(sessionKey)]" : "[AFK-#\(sessionKey)] \(trimmed)"
    }
}

// MARK: - Thread ownership

enum EmailThreadOwnership {

    /// Record `sessionKey` as the owner of `threadId`. Most recent sender wins;
    /// `firstSentAt` is preserved across re-claims so the row still says when
    /// the conversation started.
    static func record(threadId: String, sessionKey: String, dbPool: DatabasePool) async {
        guard !threadId.isEmpty, !sessionKey.isEmpty else { return }
        let now = nowMs()
        try? await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO emailThreadOwners (threadId, ownerSessionKey, firstSentAt, lastSentAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(threadId) DO UPDATE SET
                    ownerSessionKey = excluded.ownerSessionKey,
                    lastSentAt      = excluded.lastSentAt
                """, arguments: [threadId, sessionKey, now, now])
        }
    }

    /// The session that owns `threadId`, or nil when nobody has claimed it.
    static func owner(threadId: String, dbPool: DatabasePool) async -> String? {
        guard !threadId.isEmpty else { return nil }
        return try? await dbPool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT ownerSessionKey FROM emailThreadOwners WHERE threadId = ?",
                arguments: [threadId]
            )
        } ?? nil
    }

    /// The thread an already-stored message belongs to.
    static func threadId(forMessageId messageId: String, dbPool: DatabasePool) async -> String? {
        guard !messageId.isEmpty else { return nil }
        return try? await dbPool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT threadId FROM emails WHERE messageId = ?",
                arguments: [messageId]
            )
        } ?? nil
    }
}

// MARK: - Global AFK state

/// Read the Global AFK toggle straight from its table rather than through
/// `GlobalAFKController` (which is @MainActor and would drag every caller onto
/// the main thread). `globalAFK` is the controller's own persistence, so this is
/// the same fact, not a cached copy.
func globalAFKEnabled(dbPool: DatabasePool) async -> Bool {
    let enabled = try? await dbPool.read { db in
        try Int.fetchOne(db, sql: "SELECT enabled FROM globalAFK WHERE id = 1")
    }
    return (enabled ?? 0) != 0
}

// MARK: - Send gateway

/// The seam between the outbound actions and the network.
///
/// Production resolves the inbox's provider and calls it. Tests swap in a
/// recorder so the whole action — stamping, ownership, error mapping — can be
/// driven end-to-end through the real MCP dispatch without sending mail.
/// Mirrors `SidecarRegistry`'s shape (final class + NSLock + @unchecked
/// Sendable) rather than introducing a second concurrency idiom.
final class EmailOutboundGateway: @unchecked Sendable {
    static let shared = EmailOutboundGateway()

    typealias SendFn = @Sendable (_ inbox: InboxConfig, _ to: [String], _ subject: String, _ text: String) async throws -> Void
    typealias ReplyFn = @Sendable (_ inbox: InboxConfig, _ messageId: String, _ text: String) async throws -> Void

    private let lock = NSLock()
    private var sendOverride: SendFn?
    private var replyOverride: ReplyFn?
    private let resolver = EmailProviderResolver()

    // The snapshot accessors are deliberately synchronous. Taking an NSLock
    // directly inside an async function is a hard error in the Swift 6 language
    // mode (the suspension point could move the continuation to another thread
    // mid-critical-section); reading the override out in a sync call and then
    // awaiting keeps the lock off the async path entirely.
    private func snapshotSend() -> SendFn? {
        lock.lock(); defer { lock.unlock() }
        return sendOverride
    }

    private func snapshotReply() -> ReplyFn? {
        lock.lock(); defer { lock.unlock() }
        return replyOverride
    }

    func send(inbox: InboxConfig, to: [String], subject: String, text: String) async throws {
        if let override = snapshotSend() {
            try await override(inbox, to, subject, text)
            return
        }
        try await resolver.provider(for: inbox).send(
            inbox: inbox.address, to: to, subject: subject, text: text)
    }

    func reply(inbox: InboxConfig, messageId: String, text: String) async throws {
        if let override = snapshotReply() {
            try await override(inbox, messageId, text)
            return
        }
        try await resolver.provider(for: inbox).reply(
            inbox: inbox.address, messageId: messageId, text: text)
    }

    /// Test seam. Passing nil restores the live provider path.
    func setOverrides(send: SendFn?, reply: ReplyFn?) {
        lock.lock(); sendOverride = send; replyOverride = reply; lock.unlock()
    }
}

/// Resolve which inbox an outbound message goes out from. An explicit address
/// must match an enabled inbox; without one we take the oldest enabled inbox,
/// which is the same "primary inbox" convention GlobalAFKOrchestrator uses.
private func resolveOutboundInbox(
    address: String?, dbPool: DatabasePool
) async throws -> InboxConfig {
    // No `await`: the closure returns [Row], which isn't Sendable, so this
    // resolves to DatabaseReader's synchronous read overload. Writing `await`
    // here would compile but do nothing — the async overload is ineligible.
    let rows: [Row] = (try? dbPool.read { db in
        try Row.fetchAll(db, sql: """
            SELECT address, role, displayName, autoReply, dispatchTo, systemPrompt,
                   provider, providerConfig
            FROM emailInboxes
            WHERE enabled = 1
            ORDER BY createdAt ASC
        """)
    }) ?? []

    let picked: Row?
    if let address, !address.isEmpty {
        picked = rows.first { ($0["address"] as String?)?.lowercased() == address.lowercased() }
        if picked == nil {
            throw ActionError.invalidParam("inbox", "no enabled inbox matches \(address)")
        }
    } else {
        picked = rows.first
    }
    guard let row = picked else {
        throw ActionError.custom("no enabled inbox is configured", .unprocessableContent)
    }
    return InboxConfig(
        address: row["address"],
        role: InboxRole(rawValue: row["role"] as String) ?? .custom,
        displayName: row["displayName"],
        autoReply: (row["autoReply"] as Int64? ?? 1) != 0,
        dispatchTo: row["dispatchTo"],
        systemPrompt: row["systemPrompt"],
        provider: row["provider"] as String? ?? "agentmail",
        providerConfig: row["providerConfig"]
    )
}

// MARK: - Response shapes

private struct EmailSendResponse: Encodable {
    let sent: Bool
    let inbox: String
    let subject: String
    /// True when Sonata added the AFK routing tag the caller didn't have to type.
    let afkTagged: Bool
}

private struct EmailReplyResponse: Encodable {
    let sent: Bool
    let inbox: String
    let threadId: String?
    /// True when this reply claimed (or refreshed) thread ownership.
    let ownershipRecorded: Bool
}

// MARK: - Actions

let emailOutboundActions: [SonataAction] = [

    // POST /api/email/send
    SonataAction(
        name: "email_send",
        description: """
            Send an email from one of Sonata's inboxes. Prefer this over the AgentMail \
            MCP tools when you are in AFK mode: while Global AFK is on, Sonata stamps \
            the `[AFK-#<sessionId>]` routing tag into the subject for you, so the \
            user's replies come back to YOUR session as an afk_reply notification \
            instead of being dispatched to a pool worker. You never need to type the \
            routing tag yourself.
            """,
        group: "/api/email",
        path: "/send",
        method: .post,
        params: [
            ActionParam("to", .string, required: true, description: "Recipient address, or a comma-separated list"),
            ActionParam("subject", .string, required: true, description: "Subject line — the AFK routing tag is added automatically when Global AFK is on"),
            ActionParam("text", .string, required: true, description: "Plain-text body"),
            ActionParam("inbox", .string, description: "Sending inbox address (defaults to the primary configured inbox)"),
            ActionParam("sessionKey", .string, description: "Caller's session key — injected by the MCP layer, not supplied by hand"),
            ActionParam("role", .string, description: "Caller's session role — injected by the MCP layer, not supplied by hand"),
        ],
        handler: { ctx in
            guard let toRaw = ctx.params.string("to"), !toRaw.isEmpty else {
                throw ActionError.missingParam("to")
            }
            guard let subject = ctx.params.string("subject"), !subject.isEmpty else {
                throw ActionError.missingParam("subject")
            }
            guard let text = ctx.params.string("text") else {
                throw ActionError.missingParam("text")
            }
            let recipients = toRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !recipients.isEmpty else {
                throw ActionError.invalidParam("to", "no recipient addresses")
            }

            let inbox = try await resolveOutboundInbox(
                address: ctx.params.string("inbox"), dbPool: ctx.dbPool)

            // Stamp only for interactive sessions under AFK. Workers are
            // event-driven and have no afk_reply surface to route back to, so
            // tagging their mail would point replies at a session that can't
            // consume them.
            let sessionKey = ctx.params.string("sessionKey") ?? ""
            let isInteractive = (ctx.params.string("role") ?? "") == "interactive"
            let afkOn = await globalAFKEnabled(dbPool: ctx.dbPool)
            let finalSubject: String
            if afkOn, isInteractive, !sessionKey.isEmpty {
                finalSubject = AFKSubjectTag.stamp(subject: subject, sessionKey: sessionKey)
            } else {
                finalSubject = subject
            }

            do {
                try await EmailOutboundGateway.shared.send(
                    inbox: inbox, to: recipients, subject: finalSubject, text: text)
            } catch {
                throw ActionError.custom("send failed: \(error)", .badGateway)
            }

            // No ownership row here: the provider assigns the threadId and
            // doesn't hand it back, so a brand-new thread has no id to key on
            // yet. The stamped tag covers this case — the user's first reply
            // arrives tagged, EmailHandler routes it to this session, and
            // ownership is recorded at that moment (see routeAFKReplies).
            return EmailSendResponse(
                sent: true,
                inbox: inbox.address,
                subject: finalSubject,
                afkTagged: finalSubject != subject
            )
        }
    ),

    // POST /api/email/reply
    SonataAction(
        name: "email_reply",
        description: """
            Reply to an email on its existing thread, from one of Sonata's inboxes. \
            Prefer this over the AgentMail MCP tools: replying through Sonata records \
            your session as the thread's owner, so later messages on the thread are \
            routed back to you instead of being dispatched to a pool worker that would \
            appear as a second voice in the conversation.
            """,
        group: "/api/email",
        path: "/reply",
        method: .post,
        params: [
            ActionParam("messageId", .string, required: true, description: "Provider message id being replied to"),
            ActionParam("text", .string, required: true, description: "Plain-text body"),
            ActionParam("inbox", .string, description: "Sending inbox address (defaults to the primary configured inbox)"),
            ActionParam("sessionKey", .string, description: "Caller's session key — injected by the MCP layer, not supplied by hand"),
            ActionParam("role", .string, description: "Caller's session role — injected by the MCP layer, not supplied by hand"),
        ],
        handler: { ctx in
            guard let messageId = ctx.params.string("messageId"), !messageId.isEmpty else {
                throw ActionError.missingParam("messageId")
            }
            guard let text = ctx.params.string("text") else {
                throw ActionError.missingParam("text")
            }

            let inbox = try await resolveOutboundInbox(
                address: ctx.params.string("inbox"), dbPool: ctx.dbPool)

            do {
                try await EmailOutboundGateway.shared.reply(
                    inbox: inbox, messageId: messageId, text: text)
            } catch {
                throw ActionError.custom("reply failed: \(error)", .badGateway)
            }

            // Unlike send, a reply names an existing message — so the thread is
            // known and ownership can be recorded directly. Interactive sessions
            // only: a worker replying is doing dispatched work, not holding a
            // conversation, and must not become the thread's owner.
            let sessionKey = ctx.params.string("sessionKey") ?? ""
            let isInteractive = (ctx.params.string("role") ?? "") == "interactive"
            let threadId = await EmailThreadOwnership.threadId(
                forMessageId: messageId, dbPool: ctx.dbPool)
            var recorded = false
            if isInteractive, !sessionKey.isEmpty, let threadId {
                await EmailThreadOwnership.record(
                    threadId: threadId, sessionKey: sessionKey, dbPool: ctx.dbPool)
                recorded = true
            }

            return EmailReplyResponse(
                sent: true,
                inbox: inbox.address,
                threadId: threadId,
                ownershipRecorded: recorded
            )
        }
    ),
]
