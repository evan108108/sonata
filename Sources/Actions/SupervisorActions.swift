import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/supervisor routes.
// Handler logic is duplicated from SupervisorRoutes.swift.

// MARK: - Response shapes

private struct SupervisorQueryResponse: Encodable {
    let success: Bool
    let messageId: String
    let eventId: String
}

private struct SupervisorMessageItem: Encodable {
    let _id: String
    let role: String
    let content: String
    let createdAt: Int64
    let replyTo: String?
    let actions: String?
    let severity: String?
    let dismissedAt: Int64?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(replyTo, forKey: .replyTo)
        try c.encodeIfPresent(actions, forKey: .actions)
        try c.encodeIfPresent(severity, forKey: .severity)
        try c.encodeIfPresent(dismissedAt, forKey: .dismissedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, role, content, createdAt, replyTo, actions, severity, dismissedAt
    }
}

private struct SupervisorAlertResponse: Encodable {
    let success: Bool
    let alertId: String
}

private struct SupervisorStatusResponse: Encodable {
    let running: Bool
    let unreadAlerts: Int
    let lastActivity: Int64
}

let supervisorActions: [SonataAction] = [

    // POST /api/supervisor/query — user sends a message to the supervisor
    SonataAction(
        name: "mem_supervisor_query",
        description: "Send a query to the supervisor; stores the message and creates a worker event for a live supervisor worker.",
        group: "/api/supervisor",
        path: "/query",
        method: .post,
        params: [
            ActionParam("message", .string, required: true, description: "Message to supervisor"),
            ActionParam("context", .string, description: "Optional context snippet"),
        ],
        handler: { ctx in
            let message = try ctx.params.require("message")
            let context = ctx.params.string("context")

            let now = nowMs()
            let messageId = newUUID()
            let eventId = newUUID()

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: """
                        INSERT INTO supervisorMessages (id, role, content, createdAt)
                        VALUES (?, 'user', ?, ?)
                    """, arguments: [messageId, message, now])
                }

                let payload: [String: Any] = [
                    "type": "query",
                    "message": message,
                    "messageId": messageId,
                    "context": context ?? "",
                ]
                let payloadJSON = String(
                    data: try JSONSerialization.data(withJSONObject: payload),
                    encoding: .utf8
                ) ?? "{}"

                try await ctx.dbPool.write { db in
                    let supervisorId = try String.fetchOne(db, sql: """
                        SELECT workerId FROM workers WHERE sessionLabel = 'supervisor' LIMIT 1
                    """)
                    if let wid = supervisorId {
                        try db.execute(sql: """
                            INSERT INTO workerEvents (id, type, payload, priority, assignedTo, status, createdAt, assignedAt)
                            VALUES (?, 'query', ?, 10, ?, 'assigned', ?, ?)
                        """, arguments: [eventId, payloadJSON, wid, now, now])
                    }
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            return SupervisorQueryResponse(success: true, messageId: messageId, eventId: eventId)
        }
    ),

    // POST /api/supervisor/respond — supervisor posts its response
    SonataAction(
        name: "supervisor_respond",
        description: "Supervisor posts a response message.",
        group: "/api/supervisor",
        path: "/respond",
        method: .post,
        params: [
            ActionParam("messageId", .string, description: "Message id this responds to"),
            ActionParam("response", .string, required: true, description: "Response text"),
            ActionParam("actions", .stringArray, description: "Action labels performed"),
        ],
        httpOnly: true,
        handler: { ctx in
            let response = try ctx.params.require("response")
            let messageId = ctx.params.string("messageId")
            let actionsArr = ctx.params.stringArray("actions")

            let now = nowMs()
            let responseId = newUUID()
            let actionsJSON: String = actionsArr.flatMap {
                try? String(data: JSONEncoder().encode($0), encoding: .utf8)
            } ?? "[]"

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: """
                        INSERT INTO supervisorMessages (id, role, content, replyTo, actions, createdAt)
                        VALUES (?, 'assistant', ?, ?, ?, ?)
                    """, arguments: [responseId, response, messageId, actionsJSON, now])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // GET /api/supervisor/messages — list conversation history
    SonataAction(
        name: "mem_supervisor_messages",
        description: "List supervisor conversation history.",
        group: "/api/supervisor",
        path: "/messages",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 50)"),
            ActionParam("since", .integer, description: "Only messages createdAt > since (epoch ms)"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 50
            let since = ctx.params.int("since").map { Int64($0) } ?? 0

            do {
                let rows = try ctx.dbPool.read { db -> [Row] in
                    if since > 0 {
                        return try Row.fetchAll(db, sql: """
                            SELECT * FROM supervisorMessages
                            WHERE createdAt > ?
                            ORDER BY createdAt ASC
                            LIMIT ?
                        """, arguments: [since, limit])
                    } else {
                        return try Row.fetchAll(db, sql: """
                            SELECT * FROM supervisorMessages
                            ORDER BY createdAt DESC
                            LIMIT ?
                        """, arguments: [limit])
                    }
                }

                let mapped = rows.map { row -> SupervisorMessageItem in
                    SupervisorMessageItem(
                        _id: row["id"] as? String ?? "",
                        role: row["role"] as? String ?? "",
                        content: row["content"] as? String ?? "",
                        createdAt: row["createdAt"] as? Int64 ?? 0,
                        replyTo: row["replyTo"] as? String,
                        actions: row["actions"] as? String,
                        severity: row["severity"] as? String,
                        dismissedAt: row["dismissedAt"] as? Int64
                    )
                }
                return since > 0 ? mapped : mapped.reversed()
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/supervisor/report — supervisor logs autonomous actions
    SonataAction(
        name: "supervisor_report",
        description: "Supervisor logs autonomous actions / issues found summary.",
        group: "/api/supervisor",
        path: "/report",
        method: .post,
        params: [
            ActionParam("summary", .string, required: true, description: "Summary text"),
            ActionParam("actions", .stringArray, description: "Actions taken"),
            ActionParam("issuesFound", .integer, description: "Number of issues found"),
        ],
        httpOnly: true,
        handler: { ctx in
            let summary = try ctx.params.require("summary")
            let actionsArr = ctx.params.stringArray("actions")
            let issuesFound = ctx.params.int("issuesFound") ?? 0

            let now = nowMs()
            if issuesFound > 0 || !(actionsArr ?? []).isEmpty {
                let actionsJSON: String = actionsArr.flatMap {
                    try? String(data: JSONEncoder().encode($0), encoding: .utf8)
                } ?? "[]"
                do {
                    try await ctx.dbPool.write { db in
                        try db.execute(sql: """
                            INSERT INTO supervisorMessages (id, role, content, actions, createdAt)
                            VALUES (?, 'system', ?, ?, ?)
                        """, arguments: [newUUID(), summary, actionsJSON, now])
                    }
                } catch {
                    throw ActionError.database(error.localizedDescription)
                }
            }
            return SuccessResponse()
        }
    ),

    // POST /api/supervisor/alert — escalate for human attention
    SonataAction(
        name: "supervisor_alert",
        description: "Escalate a supervisor alert; persists it and fires a macOS notification.",
        group: "/api/supervisor",
        path: "/alert",
        method: .post,
        params: [
            ActionParam("title", .string, required: true, description: "Alert title"),
            ActionParam("detail", .string, required: true, description: "Alert detail"),
            ActionParam("severity", .string, description: "Severity (default 'warning')"),
            ActionParam("relatedTaskIds", .stringArray, description: "Related task ids"),
        ],
        httpOnly: true,
        handler: { ctx in
            let title = try ctx.params.require("title")
            let detail = try ctx.params.require("detail")
            let severity = ctx.params.string("severity") ?? "warning"
            let relatedTaskIds = ctx.params.stringArray("relatedTaskIds")

            let now = nowMs()
            let alertId = newUUID()
            let relatedJSON: String = relatedTaskIds.flatMap {
                try? String(data: JSONEncoder().encode($0), encoding: .utf8)
            } ?? "[]"

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: """
                        INSERT INTO supervisorMessages (id, role, content, actions, severity, createdAt)
                        VALUES (?, 'alert', ?, ?, ?, ?)
                    """, arguments: [alertId, "\(title)\n\(detail)", relatedJSON, severity, now])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            let safeTitle = title.replacingOccurrences(of: "\"", with: "'")
            let safeDetail = String(detail.prefix(200)).replacingOccurrences(of: "\"", with: "'")
            let script = "display notification \"\(safeDetail)\" with title \"Sonata Supervisor\" subtitle \"\(safeTitle)\""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()

            return SupervisorAlertResponse(success: true, alertId: alertId)
        }
    ),

    // GET /api/supervisor/status — is supervisor running?
    SonataAction(
        name: "mem_supervisor_status",
        description: "Whether the supervisor worker is running, unread alerts count, last activity timestamp.",
        group: "/api/supervisor",
        path: "/status",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                return try await ctx.dbPool.read { db -> SupervisorStatusResponse in
                    let isRunning = try Bool.fetchOne(db, sql: """
                        SELECT COUNT(*) > 0 FROM supervisorState
                        WHERE lastHeartbeat >= ?
                    """, arguments: [nowMs() - 60_000]) ?? false

                    let unreadAlerts = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM supervisorMessages
                        WHERE role = 'alert' AND dismissedAt IS NULL
                    """) ?? 0

                    let lastActivity = try Int64.fetchOne(db, sql: """
                        SELECT MAX(createdAt) FROM supervisorMessages
                    """) ?? 0

                    return SupervisorStatusResponse(
                        running: isRunning,
                        unreadAlerts: unreadAlerts,
                        lastActivity: lastActivity
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/supervisor/dismiss?id= — dismiss an alert
    SonataAction(
        name: "supervisor_dismiss",
        description: "Dismiss a supervisor alert by id.",
        group: "/api/supervisor",
        path: "/dismiss",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Alert message id", source: .query),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE supervisorMessages SET dismissedAt = ? WHERE id = ?",
                        arguments: [now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // GET /api/supervisor/events/claim — claim next unclaimed supervisor event
    SonataAction(
        name: "supervisor_claim",
        description: "Claim the next unclaimed supervisor event.",
        group: "/api/supervisor",
        path: "/events/claim",
        method: .get,
        params: [],
        httpOnly: true,
        handler: { ctx in
            let now = nowMs()
            let staleCutoff = now - 600_000
            do {
                struct ClaimedEvent: Encodable {
                    let _id: String
                    let type: String
                    let payload: String
                    let createdAt: Int64
                }
                struct NotClaimed: Encodable { let claimed: Bool }

                let claimed = try await ctx.dbPool.write { db -> ClaimedEvent? in
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT id, type, payload, createdAt FROM supervisorEvents
                        WHERE claimedAt IS NULL AND createdAt >= ?
                        ORDER BY createdAt ASC
                        LIMIT 1
                    """, arguments: [staleCutoff]) else {
                        return nil
                    }
                    let eventId = row["id"] as? String ?? ""
                    let eventType = row["type"] as? String ?? "check"
                    let payload = row["payload"] as? String ?? "{}"
                    let createdAt = row["createdAt"] as? Int64 ?? 0

                    try db.execute(sql: "UPDATE supervisorEvents SET claimedAt = ? WHERE id = ?",
                                   arguments: [now, eventId])

                    return ClaimedEvent(_id: eventId, type: eventType, payload: payload, createdAt: createdAt)
                }

                if let claimed {
                    return claimed
                } else {
                    return NotClaimed(claimed: false)
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/supervisor/heartbeat — supervisor heartbeat
    SonataAction(
        name: "supervisor_heartbeat",
        description: "Supervisor heartbeat (singleton supervisorState row).",
        group: "/api/supervisor",
        path: "/heartbeat",
        method: .post,
        params: [
            ActionParam("sessionId", .string, description: "Session id"),
        ],
        httpOnly: true,
        handler: { ctx in
            let sessionId = ctx.params.string("sessionId")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: """
                        INSERT INTO supervisorState (id, lastHeartbeat, sessionId)
                        VALUES ('singleton', ?, ?)
                        ON CONFLICT(id) DO UPDATE SET lastHeartbeat = excluded.lastHeartbeat, sessionId = COALESCE(excluded.sessionId, sessionId)
                    """, arguments: [now, sessionId])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),
]
