import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct EntityRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "entities"

    var id: String
    var name: String
    var type: String
    var description: String
    var attributesJSON: String?
    var referenceCount: Int
    var lastReferencedAt: Int64?
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, type, description
        case attributesJSON = "attributes"
        case referenceCount, lastReferencedAt
        case createdAt, updatedAt
    }
}

// MARK: - Request Bodies

struct UpsertEntityRequest: Decodable {
    let name: String
    let type: String
    let description: String
    let attributes: AnyCodable?
}

struct PatchEntityRequest: Decodable {
    let id: String
    let name: String?
    let type: String?
    let description: String?
    let attributes: AnyCodable?
}

struct TouchEntityRequest: Decodable {
    let id: String?
    let name: String?
}

struct TouchEntityResponse: Encodable {
    let id: String?
    let success: Bool
}

// MARK: - AnyCodable helper (for arbitrary JSON attributes)

struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }
}

// MARK: - Response shapes

/// Wire representation — mirrors the Convex response shape (with _id and _creationTime).
struct EntityResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let name: String
    let type: String
    let description: String
    let attributes: String?  // raw JSON string or nil
    let referenceCount: Int
    let lastReferencedAt: Int64?
    let createdAt: Int64
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(description, forKey: .description)
        // Encode attributes as raw JSON (object) rather than a string
        if let attrJSON = attributes,
           let attrData = attrJSON.data(using: .utf8),
           let attrObj = try? JSONSerialization.jsonObject(with: attrData) {
            // Re-encode the parsed JSON to get proper JSON output
            let rawData = try JSONSerialization.data(withJSONObject: attrObj)
            let rawJSON = String(data: rawData, encoding: .utf8) ?? "null"
            try c.encode(RawJSON(rawJSON), forKey: .attributes)
        } else {
            try c.encodeNil(forKey: .attributes)
        }
        try c.encode(referenceCount, forKey: .referenceCount)
        try c.encodeIfPresent(lastReferencedAt, forKey: .lastReferencedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case name, type, description, attributes
        case referenceCount, lastReferencedAt
        case createdAt, updatedAt
    }
}

/// Wrapper to emit raw JSON without double-encoding
struct RawJSON: Encodable {
    let json: String
    init(_ json: String) { self.json = json }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // We need to write the raw JSON directly
        // Since JSONEncoder will double-encode a string, we use a custom approach
        try container.encode(json)
    }
}

// MARK: - Helpers

func entityRowToResponse(_ row: EntityRow) -> EntityResponse {
    EntityResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        name: row.name,
        type: row.type,
        description: row.description,
        attributes: row.attributesJSON,
        referenceCount: row.referenceCount,
        lastReferencedAt: row.lastReferencedAt,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

private func encodeAny(_ value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
          let str = String(data: data, encoding: .utf8) else {
        return nil
    }
    return str
}

// MARK: - Route Registration

/// Register all /api/entity routes on `router`.
public func registerEntityRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/entity")

    // POST /api/entity — upsert entity by name
    api.post("/") { request, context -> Response in
        guard let body = try? await request.decode(as: UpsertEntityRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.name.isEmpty else {
            return errorResponse("name is required")
        }
        guard !body.type.isEmpty else {
            return errorResponse("type is required")
        }
        guard !body.description.isEmpty else {
            return errorResponse("description is required")
        }

        let now = nowMs()
        let attributesJSON = body.attributes.flatMap { encodeAny($0.value) }

        do {
            let resultId = try await dbPool.write { db -> String in
                // Check if entity exists by name
                let existing = try EntityRow.fetchOne(
                    db,
                    sql: "SELECT * FROM entities WHERE name = ?",
                    arguments: [body.name]
                )

                if let existing = existing {
                    // Update existing entity
                    try db.execute(
                        sql: """
                        UPDATE entities
                        SET type = ?, description = ?, attributes = COALESCE(?, attributes), updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [body.type, body.description, attributesJSON, now, existing.id]
                    )
                    return existing.id
                } else {
                    // Insert new entity
                    let id = newUUID()
                    try db.execute(
                        sql: """
                        INSERT INTO entities (id, name, type, description, attributes, referenceCount, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                        """,
                        arguments: [id, body.name, body.type, body.description, attributesJSON, now, now]
                    )
                    return id
                }
            }
            return jsonResponse(StoreResponse(id: resultId), status: .ok)
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/entity/search?q= — FTS5 search on entities
    api.get("/search") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let q = queryParams["q"].map(String.init), !q.isEmpty else {
            return errorResponse("q parameter is required")
        }
        let limit = Int(queryParams["limit"] ?? "") ?? 10
        let type = queryParams["type"].map(String.init)

        var sql = """
            SELECT e.* FROM entities e
            JOIN entities_fts fts ON fts.rowid = e.rowid
            WHERE entities_fts MATCH ?
        """
        var args: [any DatabaseValueConvertible] = [q]

        if let t = type {
            sql += " AND e.type = ?"
            args.append(t)
        }
        sql += " ORDER BY rank LIMIT ?"
        args.append(limit)

        do {
            let rows = try await dbPool.read { db in
                try EntityRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(entityRowToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/entity/get?id= — get entity by ID
    api.get("/get") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        do {
            let row = try await dbPool.read { db in
                try EntityRow.fetchOne(db, sql: "SELECT * FROM entities WHERE id = ?", arguments: [id])
            }
            guard let row else {
                return jsonResponse(Optional<String>.none, status: .notFound)
            }
            return jsonResponse(entityRowToResponse(row))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/entity/list — list entities
    api.get("/list") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        let limit = Int(queryParams["limit"] ?? "") ?? 50
        let type = queryParams["type"].map(String.init)

        var sql = "SELECT * FROM entities"
        var args: [any DatabaseValueConvertible] = []

        if let t = type {
            sql += " WHERE type = ?"
            args.append(t)
        }
        sql += " ORDER BY updatedAt DESC LIMIT ?"
        args.append(limit)

        do {
            let rows = try await dbPool.read { db in
                try EntityRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(entityRowToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/entity/relations?id=&type= — get relations for entity/memory
    api.get("/relations") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }
        let type = queryParams["type"].map(String.init) ?? "entity"

        do {
            let rows = try await dbPool.read { db -> [RelationRow] in
                // Get both outgoing and incoming relations
                let outgoing = try RelationRow.fetchAll(
                    db,
                    sql: "SELECT * FROM relations WHERE sourceId = ? AND sourceType = ?",
                    arguments: [id, type]
                )
                let incoming = try RelationRow.fetchAll(
                    db,
                    sql: "SELECT * FROM relations WHERE targetId = ? AND targetType = ?",
                    arguments: [id, type]
                )
                return outgoing + incoming
            }
            return jsonResponse(rows.map(relationRowToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/entity?name= — get entity by name
    api.get("/") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let name = queryParams["name"].map(String.init), !name.isEmpty else {
            return errorResponse("name parameter is required")
        }

        do {
            let row = try await dbPool.read { db in
                try EntityRow.fetchOne(db, sql: "SELECT * FROM entities WHERE name = ?", arguments: [name])
            }
            guard let row else {
                return jsonResponse(Optional<String>.none, status: .notFound)
            }
            return jsonResponse(entityRowToResponse(row))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // PATCH /api/entity — update entity
    api.patch("/") { request, context -> Response in
        guard let body = try? await request.decode(as: PatchEntityRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.id.isEmpty else {
            return errorResponse("id is required")
        }

        let now = nowMs()
        var setClauses: [String] = ["updatedAt = ?"]
        var args: [any DatabaseValueConvertible] = [now]

        if let v = body.name        { setClauses.append("name = ?");        args.append(v) }
        if let v = body.type        { setClauses.append("type = ?");        args.append(v) }
        if let v = body.description { setClauses.append("description = ?"); args.append(v) }
        if let v = body.attributes  {
            if let json = encodeAny(v.value) {
                setClauses.append("attributes = ?")
                args.append(json)
            }
        }

        args.append(body.id)

        let sql = "UPDATE entities SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

        do {
            try await dbPool.write { db in
                try db.execute(sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(PatchResponse(id: body.id))
    }

    // DELETE /api/entity?id= — delete entity
    api.delete("/") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: "DELETE FROM entities WHERE id = ?", arguments: [id])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/entity/touch — increment referenceCount
    api.post("/touch") { request, context -> Response in
        guard let body = try? await request.decode(as: TouchEntityRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }

        let now = nowMs()

        do {
            let resultId: String? = try await dbPool.write { db -> String? in
                if let name = body.name, !name.isEmpty {
                    // Touch by name
                    let row = try EntityRow.fetchOne(
                        db,
                        sql: "SELECT * FROM entities WHERE name = ?",
                        arguments: [name]
                    )
                    guard let row else { return nil }
                    try db.execute(
                        sql: """
                        UPDATE entities
                        SET referenceCount = referenceCount + 1,
                            lastReferencedAt = ?,
                            updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [now, now, row.id]
                    )
                    return row.id
                } else if let id = body.id, !id.isEmpty {
                    // Touch by ID
                    let row = try EntityRow.fetchOne(
                        db,
                        sql: "SELECT * FROM entities WHERE id = ?",
                        arguments: [id]
                    )
                    guard let row else { return nil }
                    try db.execute(
                        sql: """
                        UPDATE entities
                        SET referenceCount = referenceCount + 1,
                            lastReferencedAt = ?,
                            updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [now, now, row.id]
                    )
                    return row.id
                }
                return nil
            }
            return jsonResponse(TouchEntityResponse(id: resultId, success: resultId != nil))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}
