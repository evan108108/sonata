import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct WikiPageRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "wikiPages"

    var id: String
    var slug: String
    var title: String
    var namespace: String?
    var pageType: String?
    var parentSlug: String?
    var topic: String?
    var lastCompiled: Int64
    var memoryCount: Int
    var dirty: Bool
    var documentId: String?
    var filePath: String
    var abstract: String?
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, slug, title, namespace, pageType, parentSlug, topic
        case lastCompiled, memoryCount, dirty, documentId, filePath, abstract
        case createdAt, updatedAt
    }
}

// MARK: - Request Bodies

struct UpsertWikiPageRequest: Decodable {
    let slug: String
    let title: String
    let namespace: String?
    let pageType: String?
    let parentSlug: String?
    let topic: String?
    let memoryCount: Int?
    let documentId: String?
    let filePath: String
    let abstract: String?
}

struct PatchWikiPageRequest: Decodable {
    let slug: String
    let title: String?
    let namespace: String?
    let pageType: String?
    let parentSlug: String?
    let topic: String?
    let lastCompiled: Int64?
    let memoryCount: Int?
    let dirty: Bool?
    let documentId: String?
    let filePath: String?
    let abstract: String?
}

// MARK: - Response Types

struct WikiPageResponse: Encodable {
    let _id: String
    let slug: String
    let title: String
    let namespace: String?
    let pageType: String?
    let parentSlug: String?
    let topic: String?
    let lastCompiled: Int64
    let memoryCount: Int
    let dirty: Bool
    let documentId: String?
    let filePath: String
    let abstract: String?
    let content: String?
    let createdAt: Int64
    let updatedAt: Int64
}

// MARK: - Helpers

private func pageToResponse(_ row: WikiPageRow) -> WikiPageResponse {
    WikiPageResponse(
        _id: row.id,
        slug: row.slug,
        title: row.title,
        namespace: row.namespace,
        pageType: row.pageType,
        parentSlug: row.parentSlug,
        topic: row.topic,
        lastCompiled: row.lastCompiled,
        memoryCount: row.memoryCount,
        dirty: row.dirty,
        documentId: row.documentId,
        filePath: row.filePath,
        abstract: row.abstract,
        content: nil,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

private func pageToResponseWithContent(_ row: WikiPageRow) -> WikiPageResponse {
    let fileContent: String? = {
        guard FileManager.default.fileExists(atPath: row.filePath) else { return nil }
        return try? String(contentsOfFile: row.filePath, encoding: .utf8)
    }()
    return WikiPageResponse(
        _id: row.id,
        slug: row.slug,
        title: row.title,
        namespace: row.namespace,
        pageType: row.pageType,
        parentSlug: row.parentSlug,
        topic: row.topic,
        lastCompiled: row.lastCompiled,
        memoryCount: row.memoryCount,
        dirty: row.dirty,
        documentId: row.documentId,
        filePath: row.filePath,
        abstract: row.abstract,
        content: fileContent,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

// MARK: - Route Registration

public func registerWikiRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/wiki")

    // GET /api/wiki/pages — list all wiki pages
    api.get("/pages") { _, _ -> Response in
        do {
            let rows = try await dbPool.read { db in
                try WikiPageRow.fetchAll(db, sql: "SELECT * FROM wikiPages ORDER BY slug ASC")
            }
            return jsonResponse(rows.map(pageToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/wiki/page?slug= — get by slug
    api.get("/page") { request, _ -> Response in
        guard let slug = request.uri.queryParameters["slug"].map(String.init), !slug.isEmpty else {
            return errorResponse("slug parameter is required")
        }

        do {
            let row = try await dbPool.read { db in
                try WikiPageRow.fetchOne(db,
                    sql: "SELECT * FROM wikiPages WHERE slug = ?",
                    arguments: [slug]
                )
            }
            guard let row else {
                return errorResponse("Wiki page not found", status: .notFound)
            }
            return jsonResponse(pageToResponseWithContent(row))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/wiki/page — upsert (by slug)
    api.post("/page") { request, context -> Response in
        guard let body = try? await request.decode(as: UpsertWikiPageRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.slug.isEmpty, !body.title.isEmpty, !body.filePath.isEmpty else {
            return errorResponse("slug, title, and filePath are required")
        }

        let now = nowMs()

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO wikiPages
                        (id, slug, title, namespace, pageType, parentSlug, topic,
                         lastCompiled, memoryCount, dirty, documentId, filePath, abstract,
                         createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                    ON CONFLICT(slug) DO UPDATE SET
                        title = excluded.title,
                        namespace = excluded.namespace,
                        pageType = excluded.pageType,
                        parentSlug = excluded.parentSlug,
                        topic = excluded.topic,
                        memoryCount = excluded.memoryCount,
                        documentId = excluded.documentId,
                        filePath = excluded.filePath,
                        abstract = excluded.abstract,
                        updatedAt = excluded.updatedAt
                    """,
                    arguments: [
                        newUUID(), body.slug, body.title,
                        body.namespace, body.pageType, body.parentSlug, body.topic,
                        now, body.memoryCount ?? 0,
                        body.documentId, body.filePath, body.abstract,
                        now, now
                    ]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse(), status: .created)
    }

    // POST /api/wiki/dirty?slug= — set dirty=true
    api.post("/dirty") { request, _ -> Response in
        guard let slug = request.uri.queryParameters["slug"].map(String.init), !slug.isEmpty else {
            return errorResponse("slug parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE wikiPages SET dirty = 1, updatedAt = ? WHERE slug = ?",
                    arguments: [now, slug]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // GET /api/wiki/dirty — list dirty pages
    api.get("/dirty") { _, _ -> Response in
        do {
            let rows = try await dbPool.read { db in
                try WikiPageRow.fetchAll(db,
                    sql: "SELECT * FROM wikiPages WHERE dirty = 1 ORDER BY lastCompiled ASC"
                )
            }
            return jsonResponse(rows.map(pageToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // PATCH /api/wiki/page — update by slug
    api.patch("/page") { request, context -> Response in
        guard let body = try? await request.decode(as: PatchWikiPageRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.slug.isEmpty else {
            return errorResponse("slug is required")
        }

        let now = nowMs()
        var setClauses: [String] = ["updatedAt = ?"]
        var args: [any DatabaseValueConvertible] = [now]

        if let v = body.title        { setClauses.append("title = ?");        args.append(v) }
        if let v = body.namespace    { setClauses.append("namespace = ?");    args.append(v) }
        if let v = body.pageType     { setClauses.append("pageType = ?");     args.append(v) }
        if let v = body.parentSlug   { setClauses.append("parentSlug = ?");   args.append(v) }
        if let v = body.topic        { setClauses.append("topic = ?");        args.append(v) }
        if let v = body.lastCompiled { setClauses.append("lastCompiled = ?"); args.append(v as Int64) }
        if let v = body.memoryCount  { setClauses.append("memoryCount = ?");  args.append(v) }
        if let v = body.dirty        { setClauses.append("dirty = ?");        args.append(v) }
        if let v = body.documentId   { setClauses.append("documentId = ?");   args.append(v) }
        if let v = body.filePath     { setClauses.append("filePath = ?");     args.append(v) }
        if let v = body.abstract     { setClauses.append("abstract = ?");     args.append(v) }

        args.append(body.slug)

        let sql = "UPDATE wikiPages SET \(setClauses.joined(separator: ", ")) WHERE slug = ?"

        do {
            try await dbPool.write { db in
                try db.execute(sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }
}
