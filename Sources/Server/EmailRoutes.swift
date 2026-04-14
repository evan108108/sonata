import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct EmailRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "emails"

    var id: String
    var messageId: String
    var threadId: String
    var fromAddr: String
    var toAddr: String
    var subject: String
    var body: String
    var status: String
    var receivedAt: Int64
    var repliedAt: Int64?
}

// MARK: - Request Bodies

struct StoreEmailRequest: Decodable {
    let messageId: String
    let threadId: String
    let from: String
    let to: String
    let subject: String
    let body: String
    let status: String?
    let receivedAt: Int64?
}

struct MarkEmailRequest: Decodable {
    let id: String?
    let messageId: String?
}

// MARK: - Response Types

struct EmailResponse: Encodable {
    let _id: String
    let messageId: String
    let threadId: String
    let from: String
    let to: String
    let subject: String
    let body: String
    let status: String
    let receivedAt: Int64
    let repliedAt: Int64?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(messageId, forKey: .messageId)
        try c.encode(threadId, forKey: .threadId)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(subject, forKey: .subject)
        try c.encode(body, forKey: .body)
        try c.encode(status, forKey: .status)
        try c.encode(receivedAt, forKey: .receivedAt)
        try c.encodeIfPresent(repliedAt, forKey: .repliedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, messageId, threadId
        case from, to, subject, body
        case status, receivedAt, repliedAt
    }
}

struct UnreadCountResponse: Encodable {
    let unread: Int
}

// MARK: - Helpers

private let validEmailStatuses: Set<String> = ["unread", "read", "replied"]

private func rowToEmailResponse(_ row: EmailRow) -> EmailResponse {
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

/// Resolve an email by id or messageId from a MarkEmailRequest
private func resolveEmailId(from body: MarkEmailRequest, dbPool: DatabasePool) async throws -> String? {
    if let id = body.id, !id.isEmpty {
        return id
    }
    if let msgId = body.messageId, !msgId.isEmpty {
        return try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM emails WHERE messageId = ?", arguments: [msgId])
        }
    }
    return nil
}

// MARK: - Route Registration

public func registerEmailRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/email")

    // GET /api/email/unread — list unread emails
    api.get("/unread") { _, _ -> Response in
        do {
            let rows = try await dbPool.read { db in
                try EmailRow.fetchAll(db, sql: """
                    SELECT * FROM emails WHERE status = 'unread'
                    ORDER BY receivedAt DESC
                """)
            }
            return jsonResponse(rows.map(rowToEmailResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/email/recent?limit= — recent emails
    api.get("/recent") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        let limit = Int(queryParams["limit"] ?? "") ?? 20

        do {
            let rows = try await dbPool.read { db in
                try EmailRow.fetchAll(db, sql: """
                    SELECT * FROM emails ORDER BY receivedAt DESC LIMIT ?
                """, arguments: [limit])
            }
            return jsonResponse(rows.map(rowToEmailResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/email/check — return count of unread
    api.get("/check") { _, _ -> Response in
        do {
            let count = try await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emails WHERE status = 'unread'") ?? 0
            }
            return jsonResponse(UnreadCountResponse(unread: count))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/email — store new email
    api.post("/") { request, context -> Response in
        guard let body = try? await request.decode(as: StoreEmailRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }

        let id = newUUID()
        let status = body.status ?? "unread"
        guard validEmailStatuses.contains(status) else {
            return errorResponse("Invalid status '\(status)'. Must be: unread, read, replied")
        }
        let receivedAt = body.receivedAt ?? nowMs()

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO emails (id, messageId, threadId, fromAddr, toAddr, subject, body, status, receivedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id, body.messageId, body.threadId,
                        body.from, body.to,
                        body.subject, body.body,
                        status, receivedAt
                    ]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(StoreResponse(id: id), status: .created)
    }

    // POST /api/email/mark-read — set status='read'
    api.post("/mark-read") { request, context -> Response in
        guard let body = try? await request.decode(as: MarkEmailRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard let resolvedId = try? await resolveEmailId(from: body, dbPool: dbPool) else {
            return errorResponse("Provide id or messageId")
        }

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE emails SET status = 'read' WHERE id = ?",
                    arguments: [resolvedId]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/email/mark-replied — set status='replied', set repliedAt
    api.post("/mark-replied") { request, context -> Response in
        guard let body = try? await request.decode(as: MarkEmailRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard let resolvedId = try? await resolveEmailId(from: body, dbPool: dbPool) else {
            return errorResponse("Provide id or messageId")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE emails SET status = 'replied', repliedAt = ? WHERE id = ?",
                    arguments: [now, resolvedId]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/email/mark-unread — set status='unread'
    api.post("/mark-unread") { request, context -> Response in
        guard let body = try? await request.decode(as: MarkEmailRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard let resolvedId = try? await resolveEmailId(from: body, dbPool: dbPool) else {
            return errorResponse("Provide id or messageId")
        }

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE emails SET status = 'unread' WHERE id = ?",
                    arguments: [resolvedId]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }
}
