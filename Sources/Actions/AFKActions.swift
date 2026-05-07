import Foundation
import GRDB

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
    let token: String
    let replyText: String
    let fromAddr: String
    let subject: String
    let messageId: String
    let receivedAt: Int64
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

    /// Enqueue a reply for whatever session owns `token`. Returns true if a
    /// session was registered and the reply was queued.
    @discardableResult
    func enqueueReply(_ reply: AFKReply) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let sessionId = registrations[reply.token]?.sessionId else { return false }
        pendingReplies[sessionId, default: []].append(reply)
        return true
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
        description: "Register a session as the AFK target for a token. EmailHandler will route [AFK:<token>] replies here.",
        group: "/api/afk",
        path: "/register",
        method: .post,
        params: [
            ActionParam("token", .string, required: true, description: "The AFK token (also embedded in the email subject)"),
            ActionParam("sessionId", .string, required: true, description: "Bridge session ID — the routing target for the reply"),
        ],
        handler: { ctx in
            let token = try ctx.params.require("token")
            let sessionId = try ctx.params.require("sessionId")
            AFKRegistry.shared.register(token: token, sessionId: sessionId)
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
            return AFKPollResponse(replies: replies)
        }
    ),
]
