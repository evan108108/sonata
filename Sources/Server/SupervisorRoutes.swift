import Foundation
import GRDB
import Hummingbird

// MARK: - Request Bodies

struct SupervisorQueryRequest: Decodable {
    let message: String
    let context: String?
}

struct SupervisorRespondRequest: Decodable {
    let messageId: String?
    let response: String
    let actions: [String]?
}

struct SupervisorReportRequest: Decodable {
    let summary: String
    let actions: [String]?
    let issuesFound: Int?
}

struct SupervisorAlertRequest: Decodable {
    let title: String
    let detail: String
    let severity: String?
    let relatedTaskIds: [String]?
}

struct SupervisorHeartbeatRequest: Decodable {
    let sessionId: String?
}

// MARK: - Routes

public func registerSupervisorRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/supervisor")

    // POST /api/supervisor/query — Send a message to the supervisor
    api.post("/query") { request, context -> Response in
        guard let body = try? await request.decode(as: SupervisorQueryRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.message.isEmpty else {
            return errorResponse("message is required")
        }

        let now = nowMs()
        let messageId = newUUID()

        do {
            // Store the user message
            try await dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO supervisorMessages (id, role, content, createdAt)
                    VALUES (?, 'user', ?, ?)
                """, arguments: [messageId, body.message, now])
            }

            // Create a channel event for the supervisor worker
            let eventId = newUUID()
            let payload: [String: Any] = [
                "type": "query",
                "message": body.message,
                "messageId": messageId,
                "context": body.context ?? "",
            ]
            let payloadJSON = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"

            try await dbPool.write { db in
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

            let result: [String: Any] = ["success": true, "messageId": messageId, "eventId": eventId]
            let data = try JSONSerialization.data(withJSONObject: result)
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: data)))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/supervisor/respond — Supervisor posts its response
    api.post("/respond") { request, context -> Response in
        guard let body = try? await request.decode(as: SupervisorRespondRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }

        let now = nowMs()
        let responseId = newUUID()
        let actionsJSON = (body.actions.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }) ?? "[]"

        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO supervisorMessages (id, role, content, replyTo, actions, createdAt)
                    VALUES (?, 'assistant', ?, ?, ?, ?)
                """, arguments: [responseId, body.response, body.messageId, actionsJSON, now])
            }
            return jsonResponse(SuccessResponse())
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/supervisor/messages — List conversation history
    api.get("/messages") { request, _ -> Response in
        let limit = Int(request.uri.queryParameters["limit"].map(String.init) ?? "50") ?? 50
        let since = Int64(request.uri.queryParameters["since"].map(String.init) ?? "0") ?? 0

        do {
            let rows = try dbPool.read { db -> [Row] in
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

            let result = rows.map { row -> [String: Any] in
                var dict: [String: Any] = [
                    "_id": row["id"] as? String ?? "",
                    "role": row["role"] as? String ?? "",
                    "content": row["content"] as? String ?? "",
                    "createdAt": row["createdAt"] as? Int64 ?? 0,
                ]
                if let replyTo = row["replyTo"] as? String { dict["replyTo"] = replyTo }
                if let actions = row["actions"] as? String { dict["actions"] = actions }
                if let severity = row["severity"] as? String { dict["severity"] = severity }
                if let dismissedAt = row["dismissedAt"] as? Int64 { dict["dismissedAt"] = dismissedAt }
                return dict
            }

            let ordered = since > 0 ? result : result.reversed()
            let data = try JSONSerialization.data(withJSONObject: ordered)
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: data)))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/supervisor/report — Supervisor logs autonomous actions
    api.post("/report") { request, context -> Response in
        guard let body = try? await request.decode(as: SupervisorReportRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }

        let now = nowMs()
        // Only store if actions were taken or issues found
        if (body.issuesFound ?? 0) > 0 || !(body.actions ?? []).isEmpty {
            let actionsJSON = (body.actions.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }) ?? "[]"
            do {
                try await dbPool.write { db in
                    try db.execute(sql: """
                        INSERT INTO supervisorMessages (id, role, content, actions, createdAt)
                        VALUES (?, 'system', ?, ?, ?)
                    """, arguments: [newUUID(), body.summary, actionsJSON, now])
                }
            } catch {
                return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
            }
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/supervisor/alert — Escalate something needing human attention
    api.post("/alert") { request, context -> Response in
        guard let body = try? await request.decode(as: SupervisorAlertRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }

        let now = nowMs()
        let alertId = newUUID()
        let relatedJSON = (body.relatedTaskIds.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }) ?? "[]"

        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO supervisorMessages (id, role, content, actions, severity, createdAt)
                    VALUES (?, 'alert', ?, ?, ?, ?)
                """, arguments: [alertId, "\(body.title)\n\(body.detail)", relatedJSON, body.severity ?? "warning", now])
            }

            // Fire macOS notification via osascript
            let safeTitle = body.title.replacingOccurrences(of: "\"", with: "'")
            let safeDetail = String(body.detail.prefix(200)).replacingOccurrences(of: "\"", with: "'")
            let script = "display notification \"\(safeDetail)\" with title \"Sonata Supervisor\" subtitle \"\(safeTitle)\""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()

            let result: [String: Any] = ["success": true, "alertId": alertId]
            let data = try JSONSerialization.data(withJSONObject: result)
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: data)))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/supervisor/status — Is the supervisor running?
    api.get("/status") { _, _ -> Response in
        do {
            let result = try await dbPool.read { db -> [String: Any] in
                let isRunning = try Bool.fetchOne(db, sql: """
                    SELECT COUNT(*) > 0 FROM workers
                    WHERE sessionLabel = 'supervisor' AND lastHeartbeat >= ?
                """, arguments: [nowMs() - 60_000]) ?? false

                let unreadAlerts = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM supervisorMessages
                    WHERE role = 'alert' AND dismissedAt IS NULL
                """) ?? 0

                let lastActivity = try Int64.fetchOne(db, sql: """
                    SELECT MAX(createdAt) FROM supervisorMessages
                """) ?? 0

                return ["running": isRunning, "unreadAlerts": unreadAlerts, "lastActivity": lastActivity]
            }
            let data = try JSONSerialization.data(withJSONObject: result)
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: data)))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/supervisor/dismiss?id= — Dismiss an alert
    api.post("/dismiss") { request, _ -> Response in
        guard let id = request.uri.queryParameters["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }
        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(sql: "UPDATE supervisorMessages SET dismissedAt = ? WHERE id = ?",
                               arguments: [now, id])
            }
            return jsonResponse(SuccessResponse())
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/supervisor/events/claim — get next unclaimed supervisor event
    api.get("/events/claim") { _, _ -> Response in
        let now = nowMs()
        let staleCutoff = now - 600_000  // Skip events older than 10 minutes
        do {
            let claimed = try await dbPool.write { db -> (id: String, type: String, payload: String, createdAt: Int64)? in
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

                return (eventId, eventType, payload, createdAt)
            }

            if let claimed {
                let result: [String: Any] = [
                    "_id": claimed.id,
                    "type": claimed.type,
                    "payload": claimed.payload,
                    "createdAt": claimed.createdAt,
                ]
                let data = try JSONSerialization.data(withJSONObject: result)
                return Response(status: .ok, headers: [.contentType: "application/json"],
                                body: .init(byteBuffer: .init(data: data)))
            } else {
                return jsonResponse(["claimed": false] as [String: Bool])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/supervisor/heartbeat — Supervisor heartbeat (separate from worker heartbeat)
    api.post("/heartbeat") { request, context -> Response in
        let body = try? await request.decode(as: SupervisorHeartbeatRequest.self, context: context)
        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO supervisorState (id, lastHeartbeat, sessionId)
                    VALUES ('singleton', ?, ?)
                    ON CONFLICT(id) DO UPDATE SET lastHeartbeat = excluded.lastHeartbeat, sessionId = COALESCE(excluded.sessionId, sessionId)
                """, arguments: [now, body?.sessionId])
            }
            return jsonResponse(SuccessResponse())
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}
