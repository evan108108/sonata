import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/wiki routes.
// Handler logic duplicated from WikiRoutes.swift.

private func pageRowToResponseForAction(_ row: WikiPageRow) -> WikiPageResponse {
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

private func pageRowToResponseWithContentForAction(_ row: WikiPageRow) -> WikiPageResponse {
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

let wikiActions: [SonataAction] = [

    // GET /api/wiki/pages
    SonataAction(
        name: "wiki_pages",
        description: "List all wiki pages (without file content).",
        group: "/api/wiki",
        path: "/pages",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let rows = try await ctx.dbPool.read { db in
                    try WikiPageRow.fetchAll(db, sql: "SELECT * FROM wikiPages ORDER BY slug ASC")
                }
                return rows.map(pageRowToResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/wiki/page?slug=
    SonataAction(
        name: "mem_wiki_read",
        description: "Read a wiki page by slug, including its file content.",
        group: "/api/wiki",
        path: "/page",
        method: .get,
        params: [
            ActionParam("slug", .string, required: true, description: "Wiki page slug"),
        ],
        handler: { ctx in
            let slug = try ctx.params.require("slug")
            do {
                let row = try await ctx.dbPool.read { db in
                    try WikiPageRow.fetchOne(db,
                        sql: "SELECT * FROM wikiPages WHERE slug = ?",
                        arguments: [slug]
                    )
                }
                guard let row else {
                    throw ActionError.notFound("Wiki page not found")
                }
                return pageRowToResponseWithContentForAction(row)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/wiki/page
    SonataAction(
        name: "wiki_create",
        description: "Upsert a wiki page by slug.",
        group: "/api/wiki",
        path: "/page",
        method: .post,
        params: [
            ActionParam("slug", .string, required: true, description: "Unique slug"),
            ActionParam("title", .string, required: true, description: "Page title"),
            ActionParam("namespace", .string, description: "Namespace"),
            ActionParam("pageType", .string, description: "Page type"),
            ActionParam("parentSlug", .string, description: "Parent slug"),
            ActionParam("topic", .string, description: "Topic"),
            ActionParam("memoryCount", .integer, description: "Memory count (default 0)"),
            ActionParam("documentId", .string, description: "Backing document id"),
            ActionParam("filePath", .string, required: true, description: "Absolute file path"),
            ActionParam("abstract", .string, description: "Abstract"),
        ],
        handler: { ctx in
            let slug = try ctx.params.require("slug")
            let title = try ctx.params.require("title")
            let filePath = try ctx.params.require("filePath")

            // Derive structural fields from slug if caller omitted them.
            // Slug shape is the source of truth for hierarchy — namespace
            // and parentSlug must agree with it or the wiki UI splits.
            let segments = slug.split(separator: "/").map(String.init)
            let firstSeg = segments.first ?? slug
            let lastSeg = segments.last ?? slug
            let derivedParent: String? = segments.count > 1
                ? segments.dropLast().joined(separator: "/")
                : nil
            let derivedPageType = segments.count > 1 ? "topic" : "category"

            let namespace = ctx.params.string("namespace") ?? firstSeg
            let pageType = ctx.params.string("pageType") ?? derivedPageType
            let parentSlug = ctx.params.string("parentSlug") ?? derivedParent
            let topic = ctx.params.string("topic") ?? lastSeg

            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
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
                            newUUID(), slug, title,
                            namespace, pageType,
                            parentSlug, topic,
                            now, ctx.params.int("memoryCount") ?? 0,
                            ctx.params.string("documentId"), filePath, ctx.params.string("abstract"),
                            now, now
                        ]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            return SuccessResponse()
        }
    ),

    // POST /api/wiki/dirty?slug=
    SonataAction(
        name: "wiki_dirty_mark",
        description: "Mark a wiki page dirty by slug.",
        group: "/api/wiki",
        path: "/dirty",
        method: .post,
        params: [
            ActionParam("slug", .string, required: true, description: "Page slug", source: .query),
        ],
        handler: { ctx in
            let slug = try ctx.params.require("slug")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE wikiPages SET dirty = 1, updatedAt = ? WHERE slug = ?",
                        arguments: [now, slug]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // GET /api/wiki/dirty
    SonataAction(
        name: "wiki_dirty_list",
        description: "List wiki pages marked dirty (ordered by lastCompiled ASC).",
        group: "/api/wiki",
        path: "/dirty",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let rows = try await ctx.dbPool.read { db in
                    try WikiPageRow.fetchAll(db,
                        sql: "SELECT * FROM wikiPages WHERE dirty = 1 ORDER BY lastCompiled ASC"
                    )
                }
                return rows.map(pageRowToResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/wiki/children?parentSlug=<slug>
    SonataAction(
        name: "wiki_children",
        description: "List wiki pages whose parentSlug matches the given slug.",
        group: "/api/wiki",
        path: "/children",
        method: .get,
        params: [
            ActionParam("parentSlug", .string, required: true, description: "Parent page slug"),
        ],
        handler: { ctx in
            let parentSlug = try ctx.params.require("parentSlug")
            do {
                let rows = try await ctx.dbPool.read { db in
                    try WikiPageRow.fetchAll(db,
                        sql: "SELECT * FROM wikiPages WHERE parentSlug = ? ORDER BY slug ASC",
                        arguments: [parentSlug]
                    )
                }
                return rows.map(pageRowToResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/wiki/memories/all?namespace=<ns>&topic=<topic>
    //
    // Returns all memories in the given project namespace, optionally filtered
    // by topic. Used by wiki compilation to fetch memories per page.
    SonataAction(
        name: "wiki_memories_all",
        description: "List all memories for a wiki page's namespace (project) and optional topic.",
        group: "/api/wiki",
        path: "/memories/all",
        method: .get,
        params: [
            ActionParam("namespace", .string, required: true, description: "Memory project namespace"),
            ActionParam("topic", .string, description: "Optional topic filter"),
            ActionParam("limit", .integer, description: "Max results (default 500)"),
        ],
        handler: { ctx in
            let namespace = try ctx.params.require("namespace")
            let topic = ctx.params.string("topic")
            let limit = ctx.params.int("limit") ?? 500

            var sql = "SELECT * FROM memories WHERE project = ?"
            var args: [any DatabaseValueConvertible] = [namespace]
            if let t = topic {
                sql += " AND topic = ?"
                args.append(t)
            }
            sql += " ORDER BY createdAt DESC LIMIT ?"
            args.append(limit)

            do {
                let rows = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(memRowToResponse)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // PATCH /api/wiki/page
    SonataAction(
        name: "wiki_patch",
        description: "Partial update of a wiki page by slug.",
        group: "/api/wiki",
        path: "/page",
        method: .patch,
        params: [
            ActionParam("slug", .string, required: true, description: "Page slug"),
            ActionParam("title", .string, description: "New title"),
            ActionParam("namespace", .string, description: "New namespace"),
            ActionParam("pageType", .string, description: "New page type"),
            ActionParam("parentSlug", .string, description: "New parent slug"),
            ActionParam("topic", .string, description: "New topic"),
            ActionParam("lastCompiled", .integer, description: "New lastCompiled timestamp"),
            ActionParam("memoryCount", .integer, description: "New memory count"),
            ActionParam("dirty", .boolean, description: "Dirty flag"),
            ActionParam("documentId", .string, description: "New document id"),
            ActionParam("filePath", .string, description: "New file path"),
            ActionParam("abstract", .string, description: "New abstract"),
        ],
        handler: { ctx in
            let slug = try ctx.params.require("slug")

            let now = nowMs()
            var setClauses: [String] = ["updatedAt = ?"]
            var args: [any DatabaseValueConvertible] = [now]

            if let v = ctx.params.string("title")        { setClauses.append("title = ?");        args.append(v) }
            if let v = ctx.params.string("namespace")    { setClauses.append("namespace = ?");    args.append(v) }
            if let v = ctx.params.string("pageType")     { setClauses.append("pageType = ?");     args.append(v) }
            if let v = ctx.params.string("parentSlug")   { setClauses.append("parentSlug = ?");   args.append(v) }
            if let v = ctx.params.string("topic")        { setClauses.append("topic = ?");        args.append(v) }
            if let v = ctx.params.int("lastCompiled")    { setClauses.append("lastCompiled = ?"); args.append(Int64(v)) }
            if let v = ctx.params.int("memoryCount")     { setClauses.append("memoryCount = ?");  args.append(v) }
            if let v = ctx.params.bool("dirty")          { setClauses.append("dirty = ?");        args.append(v) }
            if let v = ctx.params.string("documentId")   { setClauses.append("documentId = ?");   args.append(v) }
            if let v = ctx.params.string("filePath")     { setClauses.append("filePath = ?");     args.append(v) }
            if let v = ctx.params.string("abstract")     { setClauses.append("abstract = ?");     args.append(v) }

            args.append(slug)
            let sql = "UPDATE wikiPages SET \(setClauses.joined(separator: ", ")) WHERE slug = ?"

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: sql, arguments: StatementArguments(args))
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),
]
