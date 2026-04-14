import Foundation
import Hummingbird
import GRDB

// MARK: - Memory Types

private let validMemoryTypes: Set<String> = [
    "learning", "observation", "decision", "preference",
    "error_pattern", "code_pattern", "conversation_summary",
    "reflection", "feeling", "fact"
]

// MARK: - Database Row

struct MemoryRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "memories"

    var id: String
    var content: String
    var type: String
    var tagsJSON: String
    var source: String?
    var importance: Double
    var l0: String?
    var l1: String?
    var accessCount: Int?
    var lastAccessedAt: Int64?
    var status: String?
    var supersededBy: String?
    var revisionOf: String?
    var revisionNote: String?
    var validFrom: Int64?
    var validUntil: Int64?
    var project: String?
    var topic: String?
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, content, type
        case tagsJSON = "tags"
        case source, importance, l0, l1
        case accessCount, lastAccessedAt
        case status, supersededBy, revisionOf, revisionNote
        case validFrom, validUntil, project, topic
        case createdAt, updatedAt
    }
}

// MARK: - Request Bodies

struct StoreMemoryRequest: Decodable {
    let content: String
    let type: String
    let tags: [String]?
    let source: String?
    let importance: Double?
    let validFrom: Int64?
    let validUntil: Int64?
    let project: String?
    let topic: String?
    let createdAt: Int64?
}

struct PatchMemoryRequest: Decodable {
    let id: String
    let content: String?
    let type: String?
    let tags: [String]?
    let source: String?
    let importance: Double?
    let l0: String?
    let l1: String?
    let status: String?
    let supersededBy: String?
    let revisionOf: String?
    let revisionNote: String?
    let validFrom: Int64?
    let validUntil: Int64?
    let project: String?
    let topic: String?
}

struct TouchRequest: Decodable {
    let ids: [String]
}

struct ReviseMemoryRequest: Decodable {
    let originalId: String
    let content: String
    let type: String?
    let tags: [String]?
    let source: String?
    let importance: Double?
    let revisionNote: String?
    let project: String?
    let topic: String?
}

struct SupersedeRequest: Decodable {
    let oldId: String
    let newId: String
}

struct ArchiveRequest: Decodable {
    let id: String
}

// Response types are in RouteHelpers.swift

/// Wire representation — mirrors the Convex response shape exactly.
/// Optional fields are omitted when nil (via custom encoder).
struct MemoryResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let content: String
    let type: String
    let tags: [String]
    let source: String?
    let importance: Double
    let l0: String?
    let l1: String?
    let accessCount: Int?
    let lastAccessedAt: Int64?
    let status: String?
    let supersededBy: String?
    let revisionOf: String?
    let revisionNote: String?
    let validFrom: Int64?
    let validUntil: Int64?
    let project: String?
    let topic: String?
    let createdAt: Int64
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encode(content, forKey: .content)
        try c.encode(type, forKey: .type)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(importance, forKey: .importance)
        try c.encodeIfPresent(l0, forKey: .l0)
        try c.encodeIfPresent(l1, forKey: .l1)
        try c.encodeIfPresent(accessCount, forKey: .accessCount)
        try c.encodeIfPresent(lastAccessedAt, forKey: .lastAccessedAt)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(supersededBy, forKey: .supersededBy)
        try c.encodeIfPresent(revisionOf, forKey: .revisionOf)
        try c.encodeIfPresent(revisionNote, forKey: .revisionNote)
        try c.encodeIfPresent(validFrom, forKey: .validFrom)
        try c.encodeIfPresent(validUntil, forKey: .validUntil)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(topic, forKey: .topic)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case content, type, tags, source, importance
        case l0, l1
        case accessCount, lastAccessedAt
        case status, supersededBy, revisionOf, revisionNote
        case validFrom, validUntil, project, topic
        case createdAt, updatedAt
    }
}

// Shared helpers (parseTags, encodeTags, jsonResponse, etc.) are in RouteHelpers.swift

private func rowToResponse(_ row: MemoryRow) -> MemoryResponse {
    MemoryResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        content: row.content,
        type: row.type,
        tags: parseTags(row.tagsJSON),
        source: row.source,
        importance: row.importance,
        l0: row.l0,
        l1: row.l1,
        accessCount: row.accessCount,
        lastAccessedAt: row.lastAccessedAt,
        status: row.status,
        supersededBy: row.supersededBy,
        revisionOf: row.revisionOf,
        revisionNote: row.revisionNote,
        validFrom: row.validFrom,
        validUntil: row.validUntil,
        project: row.project,
        topic: row.topic,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

// MARK: - Route Registration

/// Register all /api/memory routes (and the health check at /) on `router`.
/// `dbPool` must be a GRDB DatabasePool opened on the Sonata SQLite file.
public func registerMemoryRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    // GET / — health check
    router.get("/") { _, _ -> Response in
        jsonResponse(HealthResponse())
    }

    let api = router.group("/api/memory")

    // POST /api/memory — store a new memory
    api.post("/") { request, context -> Response in
        guard let body = try? await request.decode(as: StoreMemoryRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard validMemoryTypes.contains(body.type) else {
            return errorResponse("Invalid memory type '\(body.type)'")
        }

        let now = nowMs()
        let createdAt = body.createdAt ?? now
        let id = newUUID()
        let tagsJSON = encodeTags(body.tags ?? [])

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO memories
                        (id, content, type, tags, source, importance,
                         validFrom, validUntil, project, topic,
                         createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id, body.content, body.type, tagsJSON,
                        body.source, body.importance ?? 5.0,
                        body.validFrom ?? createdAt, body.validUntil,
                        body.project, body.topic,
                        createdAt, createdAt
                    ]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(StoreResponse(id: id), status: .created)
    }

    // GET /api/memory/recent — list memories ordered by createdAt DESC
    api.get("/recent") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        let limit = Int(queryParams["limit"] ?? "") ?? 20
        let type = queryParams["type"].map(String.init)
        let source = queryParams["source"].map(String.init)

        var sql = "SELECT * FROM memories m WHERE 1=1"
        var args: [any DatabaseValueConvertible] = []

        if let t = type {
            sql += " AND m.type = ?"
            args.append(t)
        }
        if let s = source {
            sql += " AND m.source = ?"
            args.append(s)
        }
        sql += " ORDER BY m.createdAt DESC LIMIT ?"
        args.append(limit)

        do {
            let rows = try await dbPool.read { db in
                try MemoryRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(rowToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/memory/search — FTS5 full-text search
    api.get("/search") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let q = queryParams["q"].map(String.init), !q.isEmpty else {
            return errorResponse("Missing required query parameter 'q'")
        }
        let limit = Int(queryParams["limit"] ?? "") ?? 10
        let type = queryParams["type"].map(String.init)
        let project = queryParams["project"].map(String.init)

        var sql: String
        var args: [any DatabaseValueConvertible] = []

        // FTS5 path — join the virtual table back to memories
        sql = """
            SELECT m.* FROM memories m
            JOIN memories_fts fts ON fts.rowid = m.rowid
            WHERE memories_fts MATCH ?
        """
        args.append(q)

        if let t = type {
            sql += " AND m.type = ?"
            args.append(t)
        }
        if let p = project {
            sql += " AND m.project = ?"
            args.append(p)
        }
        sql += " ORDER BY m.createdAt DESC LIMIT ?"
        args.append(limit)

        do {
            let rows = try await dbPool.read { db in
                try MemoryRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(rowToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/memory/touch — increment accessCount and set lastAccessedAt
    api.post("/touch") { request, context -> Response in
        guard let body = try? await request.decode(as: TouchRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        let now = nowMs()

        do {
            try await dbPool.write { db in
                for id in body.ids {
                    try db.execute(
                        sql: """
                        UPDATE memories
                        SET accessCount = COALESCE(accessCount, 0) + 1,
                            lastAccessedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [now, id]
                    )
                }
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(TouchResponse(touched: body.ids.count))
    }

    // GET /api/memory/get?id=... — Convex-compatible query-param style (used by mem.sh)
    api.get("/get") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        do {
            let row = try await dbPool.read { db in
                try MemoryRow.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
            }
            guard let row else {
                return errorResponse("Memory not found", status: .notFound)
            }
            return jsonResponse(rowToResponse(row))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/memory/:id — fetch single memory (path-param style)
    api.get("/:id") { request, context -> Response in
        let id = context.parameters.get("id", as: String.self) ?? ""
        guard !id.isEmpty else {
            return errorResponse("Missing id parameter")
        }

        do {
            let row = try await dbPool.read { db in
                try MemoryRow.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
            }
            guard let row else {
                return errorResponse("Memory not found", status: .notFound)
            }
            return jsonResponse(rowToResponse(row))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // PATCH /api/memory — partial update by id
    api.patch("/") { request, context -> Response in
        guard let body = try? await request.decode(as: PatchMemoryRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.id.isEmpty else {
            return errorResponse("Missing id field")
        }
        if let t = body.type, !validMemoryTypes.contains(t) {
            return errorResponse("Invalid memory type '\(t)'")
        }

        let now = nowMs()

        // Build SET clause dynamically from non-nil fields
        var setClauses: [String] = ["updatedAt = ?"]
        var args: [any DatabaseValueConvertible] = [now]

        if let v = body.content    { setClauses.append("content = ?");    args.append(v) }
        if let v = body.type       { setClauses.append("type = ?");       args.append(v) }
        if let v = body.tags       { setClauses.append("tags = ?");       args.append(encodeTags(v)) }
        if let v = body.source     { setClauses.append("source = ?");     args.append(v) }
        if let v = body.importance { setClauses.append("importance = ?"); args.append(v) }
        if let v = body.l0         { setClauses.append("l0 = ?");         args.append(v) }
        if let v = body.l1         { setClauses.append("l1 = ?");         args.append(v) }
        if let v = body.status     { setClauses.append("status = ?");     args.append(v) }
        if let v = body.supersededBy  { setClauses.append("supersededBy = ?");  args.append(v) }
        if let v = body.revisionOf    { setClauses.append("revisionOf = ?");    args.append(v) }
        if let v = body.revisionNote  { setClauses.append("revisionNote = ?");  args.append(v) }
        if let v = body.validFrom     { setClauses.append("validFrom = ?");     args.append(v as Int64) }
        if let v = body.validUntil    { setClauses.append("validUntil = ?");    args.append(v as Int64) }
        if let v = body.project       { setClauses.append("project = ?");       args.append(v) }
        if let v = body.topic         { setClauses.append("topic = ?");         args.append(v) }

        args.append(body.id)

        let sql = "UPDATE memories SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

        do {
            try await dbPool.write { db in
                try db.execute(sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(PatchResponse(id: body.id))
    }

    // DELETE /api/memory?id=... — Convex-compatible query-param style
    api.delete("/") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // DELETE /api/memory/:id — path-param style (also supported)
    api.delete("/:id") { request, context -> Response in
        let id = context.parameters.get("id", as: String.self) ?? ""
        guard !id.isEmpty else {
            return errorResponse("Missing id parameter")
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/memory/revise — create new memory that supersedes an existing one
    api.post("/revise") { request, context -> Response in
        guard let body = try? await request.decode(as: ReviseMemoryRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }

        // Fetch original to inherit fields
        let original: MemoryRow?
        do {
            original = try await dbPool.read { db in
                try MemoryRow.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [body.originalId])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
        guard let orig = original else {
            return errorResponse("Original memory not found", status: .notFound)
        }

        let now = nowMs()
        let newId = newUUID()
        let newType = body.type ?? orig.type
        guard validMemoryTypes.contains(newType) else {
            return errorResponse("Invalid memory type '\(newType)'")
        }
        let tagsJSON = body.tags.map(encodeTags) ?? orig.tagsJSON

        do {
            try await dbPool.write { db in
                // Insert the revised memory
                try db.execute(
                    sql: """
                    INSERT INTO memories
                        (id, content, type, tags, source, importance,
                         revisionOf, revisionNote, project, topic,
                         validFrom, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        newId, body.content, newType, tagsJSON,
                        body.source ?? orig.source,
                        body.importance ?? orig.importance,
                        body.originalId, body.revisionNote,
                        body.project ?? orig.project,
                        body.topic ?? orig.topic,
                        now, now, now
                    ]
                )
                // Mark old as superseded
                try db.execute(
                    sql: """
                    UPDATE memories
                    SET supersededBy = ?, status = 'superseded', updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [newId, now, body.originalId]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(StoreResponse(id: newId), status: .created)
    }

    // POST /api/memory/supersede — mark old as superseded, link to new
    api.post("/supersede") { request, context -> Response in
        guard let body = try? await request.decode(as: SupersedeRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.oldId.isEmpty, !body.newId.isEmpty else {
            return errorResponse("Both oldId and newId are required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    UPDATE memories
                    SET supersededBy = ?, status = 'superseded', updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [body.newId, now, body.oldId]
                )
                try db.execute(
                    sql: """
                    UPDATE memories
                    SET revisionOf = ?, updatedAt = ?
                    WHERE id = ? AND revisionOf IS NULL
                    """,
                    arguments: [body.oldId, now, body.newId]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/memory/archive?id= — set status='archived'
    api.post("/archive") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE memories SET status = 'archived', updatedAt = ? WHERE id = ?",
                    arguments: [now, id]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/memory/unarchive?id= — set status='active'
    api.post("/unarchive") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE memories SET status = 'active', updatedAt = ? WHERE id = ?",
                    arguments: [now, id]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }
}
