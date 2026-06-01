import Foundation
import GRDB
import Logging

private let afkLogger = Logger(label: "sonata.afk")

// AFK channel-push routing: replaces inbox polling.
//
// An AFK session calls `afk_register(token)` after sending its question email.
// EmailHandler watches for `[AFK:<token>]` subjects on inbound mail; when one
// matches, it enqueues an `afk_reply` into this registry. The bridge polls
// `/api/afk/poll` and pushes the reply into the session via the channel
// notification, waking up the waiting AFK turn without inbox polling.
//
// State is in-memory only — AFK is transient per-session.

struct AFKReply: Codable, Sendable {
    let id: String          // stable id — the ack key for the outbox (FIX #2)
    let token: String
    let replyText: String
    let fromAddr: String
    let subject: String
    let messageId: String
    let receivedAt: Int64

    init(
        id: String = UUID().uuidString,
        token: String,
        replyText: String,
        fromAddr: String,
        subject: String,
        messageId: String,
        receivedAt: Int64
    ) {
        self.id = id
        self.token = token
        self.replyText = replyText
        self.fromAddr = fromAddr
        self.subject = subject
        self.messageId = messageId
        self.receivedAt = receivedAt
    }

    // Tolerant decode: a legacy reply persisted without an id still gets one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.token = try c.decode(String.self, forKey: .token)
        self.replyText = try c.decode(String.self, forKey: .replyText)
        self.fromAddr = try c.decode(String.self, forKey: .fromAddr)
        self.subject = try c.decode(String.self, forKey: .subject)
        self.messageId = try c.decode(String.self, forKey: .messageId)
        self.receivedAt = try c.decode(Int64.self, forKey: .receivedAt)
    }
}

struct AFKRegistration: Sendable {
    let token: String
    let sessionId: String
    let registeredAt: Int64
}

final class AFKRegistry: @unchecked Sendable {
    static let shared = AFKRegistry()

    private let lock = NSLock()
    private var registrations: [String: AFKRegistration] = [:]   // token → registration
    private var pendingReplies: [String: [AFKReply]] = [:]
    // Delivery hook for the in-app MCP server (MCPNotificationDispatcher).
    // When set, enqueueReply invokes it inline INSTEAD of queueing into
    // pendingReplies. The polling endpoint (/api/afk/poll) keeps working
    // for the legacy bridge during Phase B/C by reading whatever happened
    // to be queued before the hook was installed.
    private var deliveryHook: (@Sendable (String, AFKReply) -> Void)?

    func setDeliveryHook(_ hook: @escaping @Sendable (String, AFKReply) -> Void) {
        lock.lock(); defer { lock.unlock() }
        deliveryHook = hook
    }

    /// Replay queued replies through the hook after binding. Idempotent.
    /// MCPNotificationDispatcher.bind calls this immediately after
    /// setDeliveryHook so any AFK replies that landed in the boot gap
    /// fire as channel notifications rather than sitting in the polling
    /// queue forever.
    func drainPendingForHook() {
        lock.lock()
        let hook = deliveryHook
        guard hook != nil else { lock.unlock(); return }
        // Snapshot WITHOUT clearing — the hook acks each reply (ackReply) only
        // on a confirmed push, so a failed delivery during the boot drain keeps
        // the reply durable for the next reconnect/poll (FIX #2).
        let snapshot = pendingReplies
        lock.unlock()
        for (sessionId, replies) in snapshot {
            for reply in replies { hook?(sessionId, reply) }
        }
    }

    func register(token: String, sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        registrations[token] = AFKRegistration(
            token: token,
            sessionId: sessionId,
            registeredAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    func unregister(token: String) {
        lock.lock(); defer { lock.unlock() }
        registrations.removeValue(forKey: token)
    }

    func lookupSession(token: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return registrations[token]?.sessionId
    }

    /// Snapshot of all currently-registered AFK sessions, ordered by registeredAt ASC.
    func listRegistrations() -> [AFKRegistration] {
        lock.lock(); defer { lock.unlock() }
        return registrations.values.sorted { $0.registeredAt < $1.registeredAt }
    }

    /// Number of tokens currently routed to a given sessionId. Used by the
    /// bridge to choose fast vs idle poll cadence — when nobody has registered
    /// for our sessionId we can back off the poll loop.
    func tokenCount(for sessionId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return registrations.values.reduce(0) { $0 + ($1.sessionId == sessionId ? 1 : 0) }
    }

    /// Enqueue a reply for whatever session owns `token`. Returns true if a
    /// session was registered. When the in-app MCP delivery hook is set,
    /// the reply fires inline through it; otherwise it queues into
    /// pendingReplies for the legacy /api/afk/poll path to drain.
    @discardableResult
    func enqueueReply(_ reply: AFKReply) -> Bool {
        lock.lock()
        guard let sessionId = registrations[reply.token]?.sessionId else {
            lock.unlock()
            return false
        }
        // FIX #2 — outbox / at-least-once. ALWAYS persist first, THEN deliver.
        // The hook is a best-effort push; ackReply removes the entry only on a
        // confirmed delivery. A failed push (dead SSE writer) leaves the reply
        // durable so the next reconnect/poll drains it — instead of the reply
        // being lost AND reported delivered, which is what happened before.
        pendingReplies[sessionId, default: []].append(reply)
        let hook = deliveryHook
        lock.unlock()
        hook?(sessionId, reply)
        return true
    }

    /// Remove a single delivered reply from the outbox after a confirmed push.
    /// Called by the delivery hook when pushChannel returns true. No-op if the
    /// reply was already drained (e.g. by /api/afk/poll).
    func ackReply(sessionId: String, replyId: String) {
        lock.lock(); defer { lock.unlock() }
        guard var replies = pendingReplies[sessionId] else { return }
        replies.removeAll { $0.id == replyId }
        if replies.isEmpty {
            pendingReplies[sessionId] = nil
        } else {
            pendingReplies[sessionId] = replies
        }
    }

    /// Drain pending replies for a session. Bridge calls this on each poll.
    func claimReplies(sessionId: String) -> [AFKReply] {
        lock.lock(); defer { lock.unlock() }
        let replies = pendingReplies[sessionId] ?? []
        pendingReplies[sessionId] = nil
        return replies
    }
}

private struct AFKLookupResponse: Encodable {
    let sessionId: String
    let found: Bool
}

private struct AFKPollResponse: Encodable {
    let replies: [AFKReply]
    let tokensRegistered: Int
}

private struct AFKActiveEntry: Encodable {
    let token: String
    let workerId: String       // bridge sessionId — the routing target
    let registeredAt: Int64
    let workerLabel: String?   // sessionLabel from workers table when found
}

private struct AFKActiveResponse: Encodable {
    let entries: [AFKActiveEntry]
    let generatedAt: Int64
}

let afkActions: [SonataAction] = [

    SonataAction(
        name: "afk_register",
        description: "Register this session as the AFK target for a token. EmailHandler will route [AFK:<token>] replies here, and the sibling sonata-bridge process will deliver them as channel notifications. When called via mcp__memory__, the sessionId is auto-injected from the sibling bridge; direct HTTP callers must pass sessionId explicitly.",
        group: "/api/afk",
        path: "/register",
        method: .post,
        params: [
            ActionParam("token", .string, required: true, description: "The AFK token (also embedded in the email subject)"),
            ActionParam("sessionId", .string, required: true, description: "Bridge session ID — the routing target for the reply. Auto-injected by mem-server.ts when not provided by the caller."),
        ],
        handler: { ctx in
            let token = try ctx.params.require("token")
            let sessionId = try ctx.params.require("sessionId")
            AFKRegistry.shared.register(token: token, sessionId: sessionId)

            // Sanity check: warn (but still register) if no MCP session is
            // attached for this sessionId. Workers live in the `workers`
            // table; interactive sessions live in MCPSessionRegistry (SSE
            // attach is the presence signal). A miss in both means the
            // reply will sit in pendingReplies forever.
            let isLiveWorker: Bool = (try? await ctx.dbPool.read { db -> Bool in
                let sql = "SELECT 1 FROM workers WHERE sessionId = ? LIMIT 1"
                return try Row.fetchOne(db, sql: sql, arguments: [sessionId]) != nil
            }) ?? false
            let hasMCPSession: Bool = await {
                guard let reg = MCPSessionRegistry.shared else { return false }
                let snaps = await reg.snapshot()
                return snaps.contains { $0.sessionKey == sessionId && $0.hasSSE }
            }()
            if !isLiveWorker && !hasMCPSession {
                afkLogger.warning("""
                    afk_register: sessionId \(sessionId) is not a known live worker \
                    and has no SSE-attached MCP session. The token \(token) was stored, \
                    but no delivery path appears active — AFK replies may never reach \
                    the caller. Verify the session has the sonata-bridge MCP entry \
                    pointing at http://localhost:3211/mcp/<sessionId>.
                    """)
            }
            return SuccessResponse()
        }
    ),

    SonataAction(
        name: "afk_unregister",
        description: "Unregister an AFK token. Called on AFK exit.",
        group: "/api/afk",
        path: "/unregister",
        method: .post,
        params: [
            ActionParam("token", .string, required: true, description: "The AFK token to unregister"),
        ],
        handler: { ctx in
            let token = try ctx.params.require("token")
            AFKRegistry.shared.unregister(token: token)
            return SuccessResponse()
        }
    ),

    SonataAction(
        name: "afk_lookup",
        description: "Look up the session ID registered for an AFK token.",
        group: "/api/afk",
        path: "/lookup",
        method: .get,
        params: [
            ActionParam("token", .string, required: true, description: "The AFK token", source: .query),
        ],
        handler: { ctx in
            let token = try ctx.params.require("token")
            if let sessionId = AFKRegistry.shared.lookupSession(token: token) {
                return AFKLookupResponse(sessionId: sessionId, found: true)
            }
            throw ActionError.notFound("AFK token \(token)")
        }
    ),

    SonataAction(
        name: "afk_active",
        description: "List currently-registered AFK sessions. Each entry pairs a token with the bridge session it routes to, plus the worker's friendly label (when resolvable from the workers table).",
        group: "/api/afk",
        path: "/active",
        method: .get,
        params: [],
        handler: { ctx in
            let registrations = AFKRegistry.shared.listRegistrations()
            // Resolve sessionLabel by sessionId in one batched query — empty result on error.
            var labelBySessionId: [String: String] = [:]
            if !registrations.isEmpty {
                let sessionIds = Array(Set(registrations.map { $0.sessionId }))
                do {
                    labelBySessionId = try await ctx.dbPool.read { db -> [String: String] in
                        var result: [String: String] = [:]
                        let placeholders = sessionIds.map { _ in "?" }.joined(separator: ",")
                        let sql = "SELECT sessionId, sessionLabel FROM workers WHERE sessionId IN (\(placeholders))"
                        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(sessionIds))
                        for r in rows {
                            if let sid: String = r["sessionId"] {
                                let label: String = r["sessionLabel"]
                                result[sid] = label
                            }
                        }
                        return result
                    }
                } catch {
                    // Quiet — fall back to nil labels rather than failing the whole list.
                }
            }
            let entries = registrations.map { reg in
                AFKActiveEntry(
                    token: reg.token,
                    workerId: reg.sessionId,
                    registeredAt: reg.registeredAt,
                    workerLabel: labelBySessionId[reg.sessionId]
                )
            }
            return AFKActiveResponse(entries: entries, generatedAt: Int64(Date().timeIntervalSince1970 * 1000))
        }
    ),

    SonataAction(
        name: "afk_poll",
        description: "Drain pending AFK replies for a session. The bridge calls this and pushes each reply into the Claude session via channel notification.",
        group: "/api/afk",
        path: "/poll",
        method: .get,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Bridge session ID", source: .query),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            let replies = AFKRegistry.shared.claimReplies(sessionId: sessionId)
            let tokensRegistered = AFKRegistry.shared.tokenCount(for: sessionId)
            return AFKPollResponse(replies: replies, tokensRegistered: tokensRegistered)
        }
    ),
]
