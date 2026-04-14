import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct CoreBlockRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "coreBlocks"

    var id: String
    var key: String
    var category: String
    var content: String
    var priority: Int
    var updatedAt: Int64
    var active: Bool
    var compressed: String?

    enum CodingKeys: String, CodingKey {
        case id, key, category, content, priority, updatedAt, active, compressed
    }
}

// MARK: - Request Bodies

struct UpsertCoreBlockRequest: Decodable {
    let key: String
    let category: String
    let content: String
    let priority: Int?
    let compressed: String?
}

// MARK: - Response

struct CoreBlockResponse: Encodable {
    let _id: String
    let key: String
    let category: String
    let content: String
    let priority: Int
    let updatedAt: Int64
    let active: Bool
    let compressed: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(key, forKey: .key)
        try c.encode(category, forKey: .category)
        try c.encode(content, forKey: .content)
        try c.encode(priority, forKey: .priority)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(active, forKey: .active)
        try c.encodeIfPresent(compressed, forKey: .compressed)
    }

    enum CodingKeys: String, CodingKey {
        case _id, key, category, content, priority, updatedAt, active, compressed
    }
}

// MARK: - Helpers

private func coreBlockRowToResponse(_ row: CoreBlockRow) -> CoreBlockResponse {
    CoreBlockResponse(
        _id: row.id,
        key: row.key,
        category: row.category,
        content: row.content,
        priority: row.priority,
        updatedAt: row.updatedAt,
        active: row.active,
        compressed: row.compressed
    )
}

// MARK: - Route Registration

public func registerCoreBlockRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/core")

    // GET /api/core/list — list active blocks
    api.get("/list") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        let category = queryParams["category"].map(String.init)
        let includeInactive = queryParams["all"].map(String.init) == "true"

        var sql = "SELECT * FROM coreBlocks WHERE 1=1"
        var args: [any DatabaseValueConvertible] = []

        if !includeInactive {
            sql += " AND active = 1"
        }
        if let cat = category {
            sql += " AND category = ?"
            args.append(cat)
        }
        sql += " ORDER BY priority DESC, key ASC"

        do {
            let rows = try await dbPool.read { db in
                try CoreBlockRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(coreBlockRowToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/core/get?key= — get by key
    api.get("/get") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let key = queryParams["key"].map(String.init), !key.isEmpty else {
            return errorResponse("key parameter is required")
        }

        do {
            let row = try await dbPool.read { db in
                try CoreBlockRow.fetchOne(db, sql: "SELECT * FROM coreBlocks WHERE key = ?", arguments: [key])
            }
            guard let row else {
                return errorResponse("Core block not found", status: .notFound)
            }
            return jsonResponse(coreBlockRowToResponse(row))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/core — upsert by key
    api.post("/") { request, context -> Response in
        guard let body = try? await request.decode(as: UpsertCoreBlockRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.key.isEmpty else {
            return errorResponse("key is required")
        }
        guard !body.category.isEmpty else {
            return errorResponse("category is required")
        }

        let now = nowMs()
        let priority = body.priority ?? 0

        do {
            let id = try await dbPool.write { db -> String in
                let existing = try CoreBlockRow.fetchOne(
                    db, sql: "SELECT * FROM coreBlocks WHERE key = ?", arguments: [body.key])

                if let existing {
                    try db.execute(
                        sql: """
                        UPDATE coreBlocks SET
                            category = ?, content = ?, priority = ?,
                            compressed = ?, active = 1, updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            body.category, body.content, priority,
                            body.compressed, now, existing.id
                        ]
                    )
                    return existing.id
                } else {
                    let id = newUUID()
                    try db.execute(
                        sql: """
                        INSERT INTO coreBlocks
                            (id, key, category, content, priority, updatedAt, active, compressed)
                        VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                        """,
                        arguments: [
                            id, body.key, body.category, body.content,
                            priority, now, body.compressed
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

    // POST /api/core/deactivate?key= — set active=false
    api.post("/deactivate") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let key = queryParams["key"].map(String.init), !key.isEmpty else {
            return errorResponse("key parameter is required")
        }

        let now = nowMs()

        do {
            let changed = try await dbPool.write { db -> Int in
                try db.execute(
                    sql: "UPDATE coreBlocks SET active = 0, updatedAt = ? WHERE key = ?",
                    arguments: [now, key]
                )
                return db.changesCount
            }
            guard changed > 0 else {
                return errorResponse("Core block not found", status: .notFound)
            }
            return jsonResponse(SuccessResponse())
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}
