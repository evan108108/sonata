import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct DocumentRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "documents"

    var id: String
    var title: String
    var path: String
    var content: String
    var summary: String?
    var docType: String
    var project: String?
    var tagsJSON: String
    var relatedEntitiesJSON: String?
    var relatedMemoriesJSON: String?
    var parentDoc: String?
    var source: String
    var status: String
    var createdAt: Int64
    var updatedAt: Int64
    var lastIndexedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, path, content, summary, docType, project
        case tagsJSON = "tags"
        case relatedEntitiesJSON = "relatedEntities"
        case relatedMemoriesJSON = "relatedMemories"
        case parentDoc, source, status, createdAt, updatedAt, lastIndexedAt
    }
}

// MARK: - Valid Types

private let validDocTypes: Set<String> = [
    "planning", "journal", "note", "reflection", "research", "reference"
]

private let validDocStatuses: Set<String> = [
    "draft", "active", "archived", "stale"
]

// MARK: - Request Bodies

struct IndexDocumentRequest: Decodable {
    let title: String
    let path: String
    let content: String
    let summary: String?
    let docType: String
    let project: String?
    let tags: [String]?
    let relatedEntities: [String]?
    let relatedMemories: [String]?
    let parentDoc: String?
    let source: String
    let status: String?
}

struct PatchDocumentRequest: Decodable {
    let id: String
    let title: String?
    let path: String?
    let content: String?
    let summary: String?
    let docType: String?
    let project: String?
    let tags: [String]?
    let relatedEntities: [String]?
    let relatedMemories: [String]?
    let parentDoc: String?
    let source: String?
    let status: String?
}

// MARK: - Response

struct DocumentResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let title: String
    let path: String
    let content: String
    let summary: String?
    let docType: String
    let project: String?
    let tags: [String]
    let relatedEntities: [String]?
    let relatedMemories: [String]?
    let parentDoc: String?
    let source: String
    let status: String
    let createdAt: Int64
    let updatedAt: Int64
    let lastIndexedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encode(title, forKey: .title)
        try c.encode(path, forKey: .path)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(docType, forKey: .docType)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(relatedEntities, forKey: .relatedEntities)
        try c.encodeIfPresent(relatedMemories, forKey: .relatedMemories)
        try c.encodeIfPresent(parentDoc, forKey: .parentDoc)
        try c.encode(source, forKey: .source)
        try c.encode(status, forKey: .status)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(lastIndexedAt, forKey: .lastIndexedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case title, path, content, summary, docType, project
        case tags, relatedEntities, relatedMemories, parentDoc
        case source, status, createdAt, updatedAt, lastIndexedAt
    }
}

struct DocStatRow: FetchableRecord, Decodable {
    let docType: String
    let status: String
    let count: Int
}

struct DocStatsEntry: Encodable {
    let type: String
    let status: String
    let count: Int
}

// MARK: - Helpers

private func parseJSONArray(_ json: String?) -> [String]? {
    guard let json, let data = json.data(using: .utf8),
          let arr = try? JSONDecoder().decode([String].self, from: data) else {
        return nil
    }
    return arr
}

private func encodeJSONArray(_ arr: [String]?) -> String? {
    guard let arr else { return nil }
    guard let data = try? JSONEncoder().encode(arr),
          let str = String(data: data, encoding: .utf8) else { return nil }
    return str
}

private func docRowToResponse(_ row: DocumentRow) -> DocumentResponse {
    DocumentResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        title: row.title,
        path: row.path,
        content: row.content,
        summary: row.summary,
        docType: row.docType,
        project: row.project,
        tags: parseJSONArray(row.tagsJSON) ?? [],
        relatedEntities: parseJSONArray(row.relatedEntitiesJSON),
        relatedMemories: parseJSONArray(row.relatedMemoriesJSON),
        parentDoc: row.parentDoc,
        source: row.source,
        status: row.status,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        lastIndexedAt: row.lastIndexedAt
    )
}

// MARK: - Route Registration

public func registerDocumentRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/doc")

    // POST /api/doc/index — upsert a document by path
    api.post("/index") { request, context -> Response in
        guard let body = try? await request.decode(as: IndexDocumentRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard validDocTypes.contains(body.docType) else {
            return errorResponse("Invalid docType '\(body.docType)'")
        }
        if let s = body.status, !validDocStatuses.contains(s) {
            return errorResponse("Invalid status '\(s)'")
        }

        let now = nowMs()
        let status = body.status ?? "active"
        let tagsJSON = encodeTags(body.tags ?? [])
        let relEntJSON = encodeJSONArray(body.relatedEntities) ?? "[]"
        let relMemJSON = encodeJSONArray(body.relatedMemories) ?? "[]"

        do {
            let id = try await dbPool.write { db -> String in
                // Check for existing document by path
                let existing = try DocumentRow.fetchOne(
                    db, sql: "SELECT * FROM documents WHERE path = ?", arguments: [body.path])

                if let existing {
                    // Update existing
                    try db.execute(
                        sql: """
                        UPDATE documents SET
                            title = ?, content = ?, summary = ?, docType = ?,
                            project = ?, tags = ?, relatedEntities = ?, relatedMemories = ?,
                            parentDoc = ?, source = ?, status = ?,
                            updatedAt = ?, lastIndexedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            body.title, body.content, body.summary, body.docType,
                            body.project, tagsJSON, relEntJSON, relMemJSON,
                            body.parentDoc, body.source, status,
                            now, now, existing.id
                        ]
                    )
                    return existing.id
                } else {
                    // Insert new
                    let id = newUUID()
                    try db.execute(
                        sql: """
                        INSERT INTO documents
                            (id, title, path, content, summary, docType, project,
                             tags, relatedEntities, relatedMemories, parentDoc,
                             source, status, createdAt, updatedAt, lastIndexedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            id, body.title, body.path, body.content, body.summary,
                            body.docType, body.project, tagsJSON, relEntJSON, relMemJSON,
                            body.parentDoc, body.source, status,
                            now, now, now
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

    // GET /api/doc/search?q= — FTS5 search
    api.get("/search") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let q = queryParams["q"].map(String.init), !q.isEmpty else {
            return errorResponse("Missing required query parameter 'q'")
        }
        let limit = Int(queryParams["limit"] ?? "") ?? 20
        let docType = queryParams["type"].map(String.init)
        let project = queryParams["project"].map(String.init)

        var sql = """
            SELECT d.* FROM documents d
            JOIN documents_fts fts ON fts.rowid = d.rowid
            WHERE documents_fts MATCH ?
        """
        var args: [any DatabaseValueConvertible] = [q]

        if let t = docType {
            sql += " AND d.docType = ?"
            args.append(t)
        }
        if let p = project {
            sql += " AND d.project = ?"
            args.append(p)
        }
        sql += " ORDER BY d.updatedAt DESC LIMIT ?"
        args.append(limit)

        do {
            let rows = try await dbPool.read { db in
                try DocumentRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(docRowToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/doc/list — list with optional filters
    api.get("/list") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        let limit = Int(queryParams["limit"] ?? "") ?? 50
        let docType = queryParams["type"].map(String.init)
        let project = queryParams["project"].map(String.init)
        let status = queryParams["status"].map(String.init)

        var sql = "SELECT * FROM documents WHERE 1=1"
        var args: [any DatabaseValueConvertible] = []

        if let t = docType {
            sql += " AND docType = ?"
            args.append(t)
        }
        if let p = project {
            sql += " AND project = ?"
            args.append(p)
        }
        if let s = status {
            sql += " AND status = ?"
            args.append(s)
        }
        sql += " ORDER BY updatedAt DESC LIMIT ?"
        args.append(limit)

        do {
            let rows = try await dbPool.read { db in
                try DocumentRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(docRowToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/doc/get?id= — get by ID
    api.get("/get") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        do {
            let row = try await dbPool.read { db in
                try DocumentRow.fetchOne(db, sql: "SELECT * FROM documents WHERE id = ?", arguments: [id])
            }
            guard let row else {
                return errorResponse("Document not found", status: .notFound)
            }
            return jsonResponse(docRowToResponse(row))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/doc/path?p= — get by path
    api.get("/path") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let p = queryParams["p"].map(String.init), !p.isEmpty else {
            return errorResponse("p parameter is required")
        }

        do {
            let row = try await dbPool.read { db in
                try DocumentRow.fetchOne(db, sql: "SELECT * FROM documents WHERE path = ?", arguments: [p])
            }
            guard let row else {
                return errorResponse("Document not found", status: .notFound)
            }
            return jsonResponse(docRowToResponse(row))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // PATCH /api/doc — partial update
    api.patch("/") { request, context -> Response in
        guard let body = try? await request.decode(as: PatchDocumentRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.id.isEmpty else {
            return errorResponse("Missing id field")
        }
        if let t = body.docType, !validDocTypes.contains(t) {
            return errorResponse("Invalid docType '\(t)'")
        }
        if let s = body.status, !validDocStatuses.contains(s) {
            return errorResponse("Invalid status '\(s)'")
        }

        let now = nowMs()
        var setClauses: [String] = ["updatedAt = ?"]
        var args: [any DatabaseValueConvertible] = [now]

        if let v = body.title            { setClauses.append("title = ?");            args.append(v) }
        if let v = body.path             { setClauses.append("path = ?");             args.append(v) }
        if let v = body.content          { setClauses.append("content = ?");          args.append(v); setClauses.append("lastIndexedAt = ?"); args.append(now) }
        if let v = body.summary          { setClauses.append("summary = ?");          args.append(v) }
        if let v = body.docType          { setClauses.append("docType = ?");          args.append(v) }
        if let v = body.project          { setClauses.append("project = ?");          args.append(v) }
        if let v = body.tags             { setClauses.append("tags = ?");             args.append(encodeTags(v)) }
        if let v = body.relatedEntities  { setClauses.append("relatedEntities = ?");  args.append(encodeJSONArray(v) ?? "[]") }
        if let v = body.relatedMemories  { setClauses.append("relatedMemories = ?");  args.append(encodeJSONArray(v) ?? "[]") }
        if let v = body.parentDoc        { setClauses.append("parentDoc = ?");        args.append(v) }
        if let v = body.source           { setClauses.append("source = ?");           args.append(v) }
        if let v = body.status           { setClauses.append("status = ?");           args.append(v) }

        args.append(body.id)
        let sql = "UPDATE documents SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

        do {
            try await dbPool.write { db in
                try db.execute(sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(PatchResponse(id: body.id))
    }

    // DELETE /api/doc?id= — delete by ID
    api.delete("/") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // GET /api/doc/stats — count by type/status
    api.get("/stats") { _, _ -> Response in
        do {
            let rows = try await dbPool.read { db in
                try DocStatRow.fetchAll(db, sql: """
                    SELECT docType, status, COUNT(*) as count
                    FROM documents
                    GROUP BY docType, status
                    ORDER BY docType, status
                """)
            }
            let entries = rows.map { DocStatsEntry(type: $0.docType, status: $0.status, count: $0.count) }
            return jsonResponse(entries)
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}
