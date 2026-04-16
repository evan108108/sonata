import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/email routes.
// Handler logic is duplicated from EmailRoutes.swift.

private let validEmailStatusesForActions: Set<String> = ["unread", "read", "replied"]

private func rowToEmailResponseForAction(_ row: EmailRow) -> EmailResponse {
    EmailResponse(
        _id: row.id,
        messageId: row.messageId,
        threadId: row.threadId,
        from: row.fromAddr,
        to: row.toAddr,
        subject: row.subject,
        body: row.body,
        status: row.status,
        receivedAt: row.receivedAt,
        repliedAt: row.repliedAt
    )
}

/// Resolve an email id from either an explicit id or a messageId.
private func resolveEmailIdForAction(
    id: String?,
    messageId: String?,
    dbPool: DatabasePool
) async throws -> String? {
    if let id, !id.isEmpty {
        return id
    }
    if let msgId = messageId, !msgId.isEmpty {
        return try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM emails WHERE messageId = ?", arguments: [msgId])
        }
    }
    return nil
}

let emailActions: [SonataAction] = [

    // GET /api/email/unread
    SonataAction(
        name: "email_unread",
        description: "List unread emails ordered by receivedAt DESC.",
        group: "/api/email",
        path: "/unread",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let rows = try await ctx.dbPool.read { db in
                    try EmailRow.fetchAll(db, sql: """
                        SELECT * FROM emails WHERE status = 'unread'
                        ORDER BY receivedAt DESC
                    """)
                }
                return rows.map(rowToEmailResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/email/recent?limit=
    SonataAction(
        name: "email_recent",
        description: "Recent emails ordered by receivedAt DESC.",
        group: "/api/email",
        path: "/recent",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 20)"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 20
            do {
                let rows = try await ctx.dbPool.read { db in
                    try EmailRow.fetchAll(db, sql: """
                        SELECT * FROM emails ORDER BY receivedAt DESC LIMIT ?
                    """, arguments: [limit])
                }
                return rows.map(rowToEmailResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/email/check — count unread
    SonataAction(
        name: "email_check",
        description: "Return the count of unread emails.",
        group: "/api/email",
        path: "/check",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let count = try await ctx.dbPool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emails WHERE status = 'unread'") ?? 0
                }
                return UnreadCountResponse(unread: count)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/email — store new email
    SonataAction(
        name: "email_store",
        description: "Store a new email record.",
        group: "/api/email",
        path: "/",
        method: .post,
        params: [
            ActionParam("messageId", .string, required: true, description: "Provider message id"),
            ActionParam("threadId", .string, required: true, description: "Provider thread id"),
            ActionParam("from", .string, required: true, description: "Sender address"),
            ActionParam("to", .string, required: true, description: "Recipient address"),
            ActionParam("subject", .string, required: true, description: "Subject line"),
            ActionParam("body", .string, required: true, description: "Body text"),
            ActionParam("status", .string, description: "Status (unread, read, replied)"),
            ActionParam("receivedAt", .integer, description: "Received at (epoch ms)"),
        ],
        handler: { ctx in
            let messageId = try ctx.params.require("messageId")
            let threadId = try ctx.params.require("threadId")
            let from = try ctx.params.require("from")
            let to = try ctx.params.require("to")
            let subject = try ctx.params.require("subject")
            let body = try ctx.params.require("body")
            let status = ctx.params.string("status") ?? "unread"
            guard validEmailStatusesForActions.contains(status) else {
                throw ActionError.invalidParam("status", "Must be: unread, read, replied")
            }
            let receivedAt = ctx.params.int("receivedAt").map { Int64($0) } ?? nowMs()

            let id = newUUID()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO emails (id, messageId, threadId, fromAddr, toAddr, subject, body, status, receivedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            id, messageId, threadId,
                            from, to,
                            subject, body,
                            status, receivedAt
                        ]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),

    // POST /api/email/mark-read
    SonataAction(
        name: "email_mark_read",
        description: "Mark an email as read (by id or messageId).",
        group: "/api/email",
        path: "/mark-read",
        method: .post,
        params: [
            ActionParam("id", .string, description: "Email row id"),
            ActionParam("messageId", .string, description: "Provider message id"),
        ],
        handler: { ctx in
            let resolved = try await resolveEmailIdForAction(
                id: ctx.params.string("id"),
                messageId: ctx.params.string("messageId"),
                dbPool: ctx.dbPool
            )
            guard let resolvedId = resolved else {
                throw ActionError.invalidParam("id", "Provide id or messageId")
            }

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE emails SET status = 'read' WHERE id = ?",
                        arguments: [resolvedId]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/email/mark-replied
    SonataAction(
        name: "email_mark_replied",
        description: "Mark an email as replied; sets repliedAt=now (by id or messageId).",
        group: "/api/email",
        path: "/mark-replied",
        method: .post,
        params: [
            ActionParam("id", .string, description: "Email row id"),
            ActionParam("messageId", .string, description: "Provider message id"),
        ],
        handler: { ctx in
            let resolved = try await resolveEmailIdForAction(
                id: ctx.params.string("id"),
                messageId: ctx.params.string("messageId"),
                dbPool: ctx.dbPool
            )
            guard let resolvedId = resolved else {
                throw ActionError.invalidParam("id", "Provide id or messageId")
            }

            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE emails SET status = 'replied', repliedAt = ? WHERE id = ?",
                        arguments: [now, resolvedId]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/email/mark-unread
    SonataAction(
        name: "email_mark_unread",
        description: "Mark an email as unread (by id or messageId).",
        group: "/api/email",
        path: "/mark-unread",
        method: .post,
        params: [
            ActionParam("id", .string, description: "Email row id"),
            ActionParam("messageId", .string, description: "Provider message id"),
        ],
        handler: { ctx in
            let resolved = try await resolveEmailIdForAction(
                id: ctx.params.string("id"),
                messageId: ctx.params.string("messageId"),
                dbPool: ctx.dbPool
            )
            guard let resolvedId = resolved else {
                throw ActionError.invalidParam("id", "Provide id or messageId")
            }

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE emails SET status = 'unread' WHERE id = ?",
                        arguments: [resolvedId]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),
]
