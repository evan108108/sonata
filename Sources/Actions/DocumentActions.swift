import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/doc routes.
// Handler logic duplicated from DocumentRoutes.swift.

private let validDocTypesForAction: Set<String> = [
    "planning", "journal", "note", "reflection", "research", "reference"
]

private let validDocStatusesForAction: Set<String> = [
    "draft", "active", "archived", "stale"
]

private func parseJSONArrayForAction(_ json: String?) -> [String]? {
    guard let json, let data = json.data(using: .utf8),
          let arr = try? JSONDecoder().decode([String].self, from: data) else {
        return nil
    }
    return arr
}

private func encodeJSONArrayForAction(_ arr: [String]?) -> String? {
    guard let arr else { return nil }
    guard let data = try? JSONEncoder().encode(arr),
          let str = String(data: data, encoding: .utf8) else { return nil }
    return str
}

private func docRowToResponseForAction(_ row: DocumentRow) -> DocumentResponse {
    DocumentResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        title: row.title,
        path: row.path,
        content: row.content,
        summary: row.summary,
        docType: row.docType,
        project: row.project,
        tags: parseJSONArrayForAction(row.tagsJSON) ?? [],
        relatedEntities: parseJSONArrayForAction(row.relatedEntitiesJSON),
        relatedMemories: parseJSONArrayForAction(row.relatedMemoriesJSON),
        parentDoc: row.parentDoc,
        source: row.source,
        status: row.status,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        lastIndexedAt: row.lastIndexedAt
    )
}

let documentActions: [SonataAction] = [

    // POST /api/doc/index — upsert a document by path
    SonataAction(
        name: "doc_index",
        description: "Upsert a document by path.",
        group: "/api/doc",
        path: "/index",
        method: .post,
        params: [
            ActionParam("title", .string, required: true, description: "Document title"),
            ActionParam("path", .string, required: true, description: "Absolute path (unique)"),
            ActionParam("content", .string, required: true, description: "Document content"),
            ActionParam("docType", .string, required: true, description: "Type: planning, journal, note, reflection, research, reference"),
            ActionParam("source", .string, required: true, description: "Source project/context"),
            ActionParam("summary", .string, description: "Short summary"),
            ActionParam("project", .string, description: "Project namespace"),
            ActionParam("parentDoc", .string, description: "Parent document id"),
            ActionParam("status", .string, description: "Status: draft, active, archived, stale"),
            ActionParam("tags", .stringArray, description: "Tags"),
            ActionParam("relatedEntities", .stringArray, description: "Related entity ids"),
            ActionParam("relatedMemories", .stringArray, description: "Related memory ids"),
        ],
        handler: { ctx in
            let title = try ctx.params.require("title")
            let path = try ctx.params.require("path")
            let content = try ctx.params.require("content")
            let docType = try ctx.params.require("docType")
            let source = try ctx.params.require("source")

            guard validDocTypesForAction.contains(docType) else {
                throw ActionError.invalidParam("docType", "Invalid docType '\(docType)'")
            }
            let statusParam = ctx.params.string("status")
            if let s = statusParam, !validDocStatusesForAction.contains(s) {
                throw ActionError.invalidParam("status", "Invalid status '\(s)'")
            }

            let now = nowMs()
            let status = statusParam ?? "active"
            let summary = ctx.params.string("summary")
            let project = ctx.params.string("project")
            let parentDoc = ctx.params.string("parentDoc")
            let tagsJSON = encodeTags(ctx.params.stringArray("tags") ?? [])
            let relEntJSON = encodeJSONArrayForAction(ctx.params.stringArray("relatedEntities")) ?? "[]"
            let relMemJSON = encodeJSONArrayForAction(ctx.params.stringArray("relatedMemories")) ?? "[]"

            do {
                let id = try await ctx.dbPool.write { db -> String in
                    let existing = try DocumentRow.fetchOne(
                        db, sql: "SELECT * FROM documents WHERE path = ?", arguments: [path])

                    if let existing {
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
                                title, content, summary, docType,
                                project, tagsJSON, relEntJSON, relMemJSON,
                                parentDoc, source, status,
                                now, now, existing.id
                            ]
                        )
                        return existing.id
                    } else {
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
                                id, title, path, content, summary,
                                docType, project, tagsJSON, relEntJSON, relMemJSON,
                                parentDoc, source, status,
                                now, now, now
                            ]
                        )
                        return id
                    }
                }
                return StoreResponse(id: id)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/doc/search — FTS5 search
    SonataAction(
        name: "mem_doc_search",
        description: "Full-text search on documents (FTS5).",
        group: "/api/doc",
        path: "/search",
        method: .get,
        params: [
            ActionParam("q", .string, required: true, description: "FTS5 query string"),
            ActionParam("limit", .integer, description: "Max results (default 20)"),
            ActionParam("type", .string, description: "Filter by docType"),
            ActionParam("project", .string, description: "Filter by project"),
        ],
        handler: { ctx in
            let q = try ctx.params.require("q")
            let limit = ctx.params.int("limit") ?? 20
            let docType = ctx.params.string("type")
            let project = ctx.params.string("project")

            let ftsQuery = ftsEscape(q)
            guard !ftsQuery.isEmpty else { return [DocumentResponse]() }

            var sql = """
                SELECT d.* FROM documents d
                JOIN documents_fts fts ON fts.rowid = d.rowid
                WHERE documents_fts MATCH ?
            """
            var args: [any DatabaseValueConvertible] = [ftsQuery]

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
                let rows = try ctx.dbPool.read { db in
                    try DocumentRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(docRowToResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/doc/list — list with optional filters
    SonataAction(
        name: "doc_list",
        description: "List documents with optional filters.",
        group: "/api/doc",
        path: "/list",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 50)"),
            ActionParam("type", .string, description: "Filter by docType"),
            ActionParam("project", .string, description: "Filter by project"),
            ActionParam("status", .string, description: "Filter by status"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 50
            let docType = ctx.params.string("type")
            let project = ctx.params.string("project")
            let status = ctx.params.string("status")

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
                let rows = try ctx.dbPool.read { db in
                    try DocumentRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(docRowToResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/doc/get?id= — get by ID
    SonataAction(
        name: "doc_get",
        description: "Get a document by id.",
        group: "/api/doc",
        path: "/get",
        method: .get,
        params: [
            ActionParam("id", .string, required: true, description: "Document ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                let row = try await ctx.dbPool.read { db in
                    try DocumentRow.fetchOne(db, sql: "SELECT * FROM documents WHERE id = ?", arguments: [id])
                }
                guard let row else {
                    throw ActionError.notFound("Document not found")
                }
                return docRowToResponseForAction(row)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/doc/path?p= — get by path
    SonataAction(
        name: "doc_path",
        description: "Get a document by path.",
        group: "/api/doc",
        path: "/path",
        method: .get,
        params: [
            ActionParam("p", .string, required: true, description: "Document path"),
        ],
        handler: { ctx in
            let p = try ctx.params.require("p")
            do {
                let row = try await ctx.dbPool.read { db in
                    try DocumentRow.fetchOne(db, sql: "SELECT * FROM documents WHERE path = ?", arguments: [p])
                }
                guard let row else {
                    throw ActionError.notFound("Document not found")
                }
                return docRowToResponseForAction(row)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // PATCH /api/doc — partial update
    SonataAction(
        name: "doc_patch",
        description: "Partial update of a document by id.",
        group: "/api/doc",
        path: "/",
        method: .patch,
        params: [
            ActionParam("id", .string, required: true, description: "Document ID"),
            ActionParam("title", .string, description: "New title"),
            ActionParam("path", .string, description: "New path"),
            ActionParam("content", .string, description: "New content"),
            ActionParam("summary", .string, description: "New summary"),
            ActionParam("docType", .string, description: "New docType"),
            ActionParam("project", .string, description: "New project"),
            ActionParam("parentDoc", .string, description: "New parent doc"),
            ActionParam("source", .string, description: "New source"),
            ActionParam("status", .string, description: "New status"),
            ActionParam("tags", .stringArray, description: "New tags"),
            ActionParam("relatedEntities", .stringArray, description: "New related entities"),
            ActionParam("relatedMemories", .stringArray, description: "New related memories"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            if let t = ctx.params.string("docType"), !validDocTypesForAction.contains(t) {
                throw ActionError.invalidParam("docType", "Invalid docType '\(t)'")
            }
            if let s = ctx.params.string("status"), !validDocStatusesForAction.contains(s) {
                throw ActionError.invalidParam("status", "Invalid status '\(s)'")
            }

            let now = nowMs()
            var setClauses: [String] = ["updatedAt = ?"]
            var args: [any DatabaseValueConvertible] = [now]

            if let v = ctx.params.string("title")            { setClauses.append("title = ?");            args.append(v) }
            if let v = ctx.params.string("path")             { setClauses.append("path = ?");             args.append(v) }
            if let v = ctx.params.string("content")          { setClauses.append("content = ?");          args.append(v); setClauses.append("lastIndexedAt = ?"); args.append(now) }
            if let v = ctx.params.string("summary")          { setClauses.append("summary = ?");          args.append(v) }
            if let v = ctx.params.string("docType")          { setClauses.append("docType = ?");          args.append(v) }
            if let v = ctx.params.string("project")          { setClauses.append("project = ?");          args.append(v) }
            if let v = ctx.params.stringArray("tags")        { setClauses.append("tags = ?");             args.append(encodeTags(v)) }
            if let v = ctx.params.stringArray("relatedEntities") { setClauses.append("relatedEntities = ?"); args.append(encodeJSONArrayForAction(v) ?? "[]") }
            if let v = ctx.params.stringArray("relatedMemories") { setClauses.append("relatedMemories = ?"); args.append(encodeJSONArrayForAction(v) ?? "[]") }
            if let v = ctx.params.string("parentDoc")        { setClauses.append("parentDoc = ?");        args.append(v) }
            if let v = ctx.params.string("source")           { setClauses.append("source = ?");           args.append(v) }
            if let v = ctx.params.string("status")           { setClauses.append("status = ?");           args.append(v) }

            args.append(id)
            let sql = "UPDATE documents SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

            do {
                try ctx.dbPool.write { db in
                    try db.execute(sql: sql, arguments: StatementArguments(args))
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            return PatchResponse(id: id)
        }
    ),

    // DELETE /api/doc?id= — delete by ID
    SonataAction(
        name: "doc_delete",
        description: "Delete a document by id.",
        group: "/api/doc",
        path: "/",
        method: .delete,
        params: [
            ActionParam("id", .string, required: true, description: "Document ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // GET /api/doc/stats — count by type/status
    SonataAction(
        name: "doc_stats",
        description: "Count documents grouped by docType and status.",
        group: "/api/doc",
        path: "/stats",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let rows = try await ctx.dbPool.read { db in
                    try DocStatRow.fetchAll(db, sql: """
                        SELECT docType, status, COUNT(*) as count
                        FROM documents
                        GROUP BY docType, status
                        ORDER BY docType, status
                    """)
                }
                return rows.map { DocStatsEntry(type: $0.docType, status: $0.status, count: $0.count) }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
