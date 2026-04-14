import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct ContactRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "contacts"

    var id: String
    var name: String
    var email: String
    var type: String
    var role: String?
    var provider: String?
    var model: String?
    var systemPrompt: String?
    var notes: String?
    var lastContactAt: Int64?
    var messageCount: Int
    var createdAt: Int64
    var updatedAt: Int64
}

// MARK: - Valid Types

private let validContactTypes: Set<String> = ["human", "ai", "service"]

// MARK: - Request Bodies

struct UpsertContactRequest: Decodable {
    let name: String
    let email: String
    let type: String
    let role: String?
    let provider: String?
    let model: String?
    let systemPrompt: String?
    let notes: String?
}

// MARK: - Response

struct ContactResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let name: String
    let email: String
    let type: String
    let role: String?
    let provider: String?
    let model: String?
    let systemPrompt: String?
    let notes: String?
    let lastContactAt: Int64?
    let messageCount: Int
    let createdAt: Int64
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encode(name, forKey: .name)
        try c.encode(email, forKey: .email)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(lastContactAt, forKey: .lastContactAt)
        try c.encode(messageCount, forKey: .messageCount)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case name, email, type, role, provider, model
        case systemPrompt, notes, lastContactAt, messageCount
        case createdAt, updatedAt
    }
}

// MARK: - Helpers

private func contactRowToResponse(_ row: ContactRow) -> ContactResponse {
    ContactResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        name: row.name,
        email: row.email,
        type: row.type,
        role: row.role,
        provider: row.provider,
        model: row.model,
        systemPrompt: row.systemPrompt,
        notes: row.notes,
        lastContactAt: row.lastContactAt,
        messageCount: row.messageCount,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

// MARK: - Route Registration

public func registerContactRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api")

    // GET /api/contacts — list all (optional type filter)
    api.get("/contacts") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        let type = queryParams["type"].map(String.init)
        let limit = Int(queryParams["limit"] ?? "") ?? 100

        var sql = "SELECT * FROM contacts WHERE 1=1"
        var args: [any DatabaseValueConvertible] = []

        if let t = type {
            sql += " AND type = ?"
            args.append(t)
        }
        sql += " ORDER BY name ASC LIMIT ?"
        args.append(limit)

        do {
            let rows = try await dbPool.read { db in
                try ContactRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(contactRowToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/contact?email= — get by email
    api.get("/contact") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let email = queryParams["email"].map(String.init), !email.isEmpty else {
            return errorResponse("email parameter is required")
        }

        do {
            let row = try await dbPool.read { db in
                try ContactRow.fetchOne(db, sql: "SELECT * FROM contacts WHERE email = ?", arguments: [email])
            }
            guard let row else {
                return errorResponse("Contact not found", status: .notFound)
            }
            return jsonResponse(contactRowToResponse(row))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/contact — upsert by email
    api.post("/contact") { request, context -> Response in
        guard let body = try? await request.decode(as: UpsertContactRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard validContactTypes.contains(body.type) else {
            return errorResponse("Invalid contact type '\(body.type)'")
        }

        let now = nowMs()

        do {
            let id = try await dbPool.write { db -> String in
                let existing = try ContactRow.fetchOne(
                    db, sql: "SELECT * FROM contacts WHERE email = ?", arguments: [body.email])

                if let existing {
                    try db.execute(
                        sql: """
                        UPDATE contacts SET
                            name = ?, type = ?, role = ?, provider = ?,
                            model = ?, systemPrompt = ?, notes = ?, updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            body.name, body.type, body.role, body.provider,
                            body.model, body.systemPrompt, body.notes, now,
                            existing.id
                        ]
                    )
                    return existing.id
                } else {
                    let id = newUUID()
                    try db.execute(
                        sql: """
                        INSERT INTO contacts
                            (id, name, email, type, role, provider, model,
                             systemPrompt, notes, messageCount, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                        """,
                        arguments: [
                            id, body.name, body.email, body.type, body.role,
                            body.provider, body.model, body.systemPrompt, body.notes,
                            now, now
                        ]
                    )
                    return id
                }
            }
            return jsonResponse(StoreResponse(id: id), status: .created)
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/contact/touch?email= — increment messageCount
    api.post("/contact/touch") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let email = queryParams["email"].map(String.init), !email.isEmpty else {
            return errorResponse("email parameter is required")
        }

        let now = nowMs()

        do {
            let changed = try await dbPool.write { db -> Int in
                try db.execute(
                    sql: """
                    UPDATE contacts SET
                        messageCount = messageCount + 1,
                        lastContactAt = ?,
                        updatedAt = ?
                    WHERE email = ?
                    """,
                    arguments: [now, now, email]
                )
                return db.changesCount
            }
            guard changed > 0 else {
                return errorResponse("Contact not found", status: .notFound)
            }
            return jsonResponse(SuccessResponse())
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // DELETE /api/contact?id= — delete by ID
    api.delete("/contact") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: "DELETE FROM contacts WHERE id = ?", arguments: [id])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }
}
